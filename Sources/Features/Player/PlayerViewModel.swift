import AVKit
import Combine
import Foundation
import QuartzCore
#if canImport(VLCKitSPM)
import VLCKitSPM
#endif

@MainActor
final class PlayerViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case buffering
        case reconnecting
        case failed(String)
    }

    /// AVPlayer is the primary engine (hardware decode, AirPlay). VLC is the
    /// fallback for codecs AVPlayer rejects on this platform (MP2 audio,
    /// interlaced video — common on IPTV panels).
    enum Engine: Equatable {
        case avPlayer
        case vlc
    }

    @Published private(set) var engine: Engine = .avPlayer
    /// Streams whose codecs AVPlayer already rejected this session — zap
    /// straight to VLC next time.
    private var vlcOnlyStreams: Set<StreamID> = []

    #if canImport(VLCKitSPM)
    private(set) var vlcPlayer: VLCMediaPlayer?
    private lazy var vlcProxy: VLCDelegateProxy = {
        let proxy = VLCDelegateProxy()
        proxy.owner = self
        return proxy
    }()
    #endif


    /// User-tunable buffering/reconnect knobs, re-read at every playback start
    /// so Settings changes apply to the next stream or reconnect.
    private var settings = PlaybackSettings.default
    private let settingsStore: PlaybackSettingsStore

    /// Monotonic token identifying the current playback session. Every async
    /// continuation — KVO hops, VLC delegate hops, scheduled retries — captures
    /// it and bails when superseded, so work belonging to a replaced player or
    /// an earlier attempt can never touch fresh state.
    private(set) var playbackGeneration: UInt64 = 0

    /// Test seam: replaces the engine start during reconnect so backoff tests
    /// run deterministically without spinning real players. nil in production.
    var reconnectStartOverride: ((LiveStream, URL) -> Void)?

    /// Test seam: replaces the AVPlayer access-log read for the transport
    /// watch. nil in production (reads the real item's access log).
    var accessLogURIsProvider: (() -> [String])?
    /// How many access-log entries the transport watch already judged, so a
    /// long session stays O(new entries) per tick instead of O(log size).
    /// Reset with every new item/session.
    private var transportCheckedURICount = 0

    /// URIs the current item's media requests actually hit. The access log is
    /// per item, so a reconnect starts a fresh history.
    private func observedAccessURIs() -> [String] {
        if let accessLogURIsProvider { return accessLogURIsProvider() }
        guard let item = player.currentItem else { return [] }
        return item.accessLog()?.events.compactMap(\.uri) ?? []
    }

    /// Post-hoc transport watch (issue #37): a media request that moved to
    /// plain http or another origin exposes the path credentials — stop the
    /// session and surface a typed error instead of continuing to feed it.
    /// Detection, not prevention: the offending request already happened once.
    /// The error copy is fixed — the observed URI never reaches a log or the
    /// UI. VLC has no access log; its gap is documented in the README.
    private func enforcePlaybackTransport() -> Bool {
        guard let currentURL else { return false }
        let uris = observedAccessURIs()
        guard uris.count > transportCheckedURICount else { return false }
        let fresh = Array(uris[transportCheckedURICount...])
        transportCheckedURICount = uris.count
        guard PlaybackTransportPolicy.firstViolation(in: fresh, plannedOrigin: currentURL) != nil else {
            return false
        }
        stop()
        state = .failed(PlaybackError.insecureTransport.errorDescription ?? "Playback stopped.")
        return true
    }

    /// Test seam: primes a session without starting a real engine, so the
    /// reconnect/backoff machinery is observable deterministically.
    func primeForReconnectTesting(stream: LiveStream, url: URL, tsURL: URL?, settings: PlaybackSettings, state: State = .idle) {
        currentStream = stream
        currentURL = url
        currentTSURL = tsURL
        self.settings = settings
        self.state = state
    }

    /// One pending scheduled reconnect at most; cancelled on stop, on a new
    /// play, and on deinit. Replaces the old reliance on the watchdog to
    /// re-drive backoff — the watchdog is disabled during VLC sessions.
    private var reconnectRetryTask: Task<Void, Never>?

    /// Injected sleep for the scheduled retry, so backoff is deterministic in
    /// tests. Production sleeps for real.
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    /// Injected wall clock for the backoff window math, same reason.
    private let now: () -> Date

    init(
        settingsStore: PlaybackSettingsStore = PlaybackSettingsStore(),
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.retrySleep = retrySleep
        self.now = now
        configureTimeControlObservation()
    }

    deinit {
        reconnectRetryTask?.cancel()
    }

    /// Swap in a fresh AVPlayer and dispose of the old one off the main
    /// thread — deallocating a wedged player can block on the same locks.
    private func replacePlayer() {
        let old = player
        statusObservation = nil
        keepUpObservation = nil
        removeNotificationObservers()
        videoOutput = nil
        DispatchQueue.global(qos: .utility).async {
            old.pause()
            _ = old // released here, off-main
        }
        player = AVPlayer()
        configureTimeControlObservation()
    }

    /// Recreated on every (re)connection: synchronous calls on a wedged
    /// AVPlayer/AVPlayerItem (replaceCurrentItem, seekableTimeRanges…) can
    /// block the main thread on internal network/decoder locks.
    @Published private(set) var player = AVPlayer()
    @Published private(set) var state: State = .idle
    @Published private(set) var currentStream: LiveStream?

    private(set) var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    /// Owns the AVPlayerItem observer tokens and the watchdog timer; tears
    /// them down on release so no nonisolated deinit has to touch
    /// non-Sendable state.
    private let teardown = TeardownBag()
    private var lastObservedTime: CMTime = .zero
    private var frozenSeconds: TimeInterval = 0
    private var waitingSince: Date?
    private(set) var reconnectAttempts = 0
    private var lastReconnectAt: Date?
    /// Raw MPEG-TS variant of the current stream, for the VLC engine.
    private(set) var currentTSURL: URL?
    /// Whether the panel advertises HLS for the current stream — retry() must
    /// preserve it, or a TS-only channel would retry into AVPlayer.
    private(set) var currentHLSAvailable = true
    /// Timestamps of recent AVPlayer stall recoveries. A channel needing
    /// several within a short window plays badly over the panel's HLS — the
    /// cure is the raw TS stream through VLC, which is what other IPTV
    /// players use and why they don't stall on the same URL.
    private var stallRecoveryEvents: [Date] = []
    /// Detects frozen *video* — audio can keep playing (clock advances) while
    /// the video track is stuck, which the currentTime check can't see.
    private var videoOutput: AVPlayerItemVideoOutput?
    /// First recovery is a cheap seek to the live edge; reconnect only if the
    /// freeze persists after that.
    private var attemptedSeekRecovery = false
    /// Latest video-surface size, reported by the platform views. Lets the
    /// geometry restart skip when the layout didn't materially change.
    private(set) var currentSurfaceSize: CGSize = .zero
    /// Surface size of the last geometry-triggered VLC restart.
    private var lastGeometryRestartSize: CGSize?

    private func configureTimeControlObservation() {
        let generation = playbackGeneration
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.currentStream != nil,
                      self.playbackGeneration == generation else { return }
                switch status {
                case .playing:
                    self.state = .playing
                    self.waitingSince = nil
                    self.noteHealthyPlayback()
                case .waitingToPlayAtSpecifiedRate:
                    if self.waitingSince == nil {
                        self.waitingSince = Date()
                    }
                    // Initial spin-up stays "loading"; mid-playback waits are buffering.
                    if self.state == .playing {
                        self.state = .buffering
                    }
                case .paused:
                    break // user-initiated pause is not an error state
                @unknown default:
                    break
                }
            }
        }
    }

    /// Do not override the User-Agent here: panels 403 anything that doesn't
    /// look like AppleCoreMedia, which is exactly AVPlayer's default.
    /// `tsURL` is the raw MPEG-TS variant the VLC engine prefers (nil for
    /// demo/sample content).
    /// `hlsAvailable: false` means the panel advertises no HLS for this
    /// stream — skip the AVPlayer attempt and lead with the VLC engine.
    func play(_ stream: LiveStream, url: URL, tsURL: URL? = nil, hlsAvailable: Bool = true) {
        cancelScheduledRetry()
        reconnectAttempts = 0
        lastReconnectAt = nil
        stallRecoveryEvents = []
        currentTSURL = tsURL
        currentHLSAvailable = hlsAvailable
        settings = settingsStore.load()
        #if canImport(VLCKitSPM)
        // Forced-VLC preference, or a channel this session already learned
        // needs VLC — skip the AVPlayer attempt entirely.
        let forceVLC = (settings.preferredEngine == .vlc && !DemoMode.isActive) || !hlsAvailable
        if forceVLC || vlcOnlyStreams.contains(stream.id) {
            currentStream = stream
            currentURL = url
            startVLCPlayback(stream, url: tsURL ?? url, as: .loading)
            return
        }
        #endif
        startPlayback(stream, url: url, as: .loading)
    }

    func retry() {
        guard let currentStream, let currentURL else { return }
        play(currentStream, url: currentURL, tsURL: currentTSURL, hlsAvailable: currentHLSAvailable)
    }

    /// URL the VLC engine should use: raw TS when the panel offers it.
    private var currentVLCURL: URL? {
        currentTSURL ?? currentURL
    }

    /// Realigns audio/video clocks by jumping to the live edge — the manual
    /// fix for A/V drift accumulated from sloppy panel transcodes.
    func resyncToLive() {
        guard currentStream != nil else { return }
        #if canImport(VLCKitSPM)
        if engine == .vlc {
            if let currentStream, let url = currentVLCURL {
                startVLCPlayback(currentStream, url: url, as: .buffering)
            }
            return
        }
        #endif
        seekTowardLiveEdge()
    }

    func fail(_ error: Error) {
        let playbackError = error as? PlaybackError ?? .itemFailed(error.localizedDescription)
        state = .failed(playbackError.errorDescription ?? "Playback failed.")
    }

    func stop() {
        playbackGeneration &+= 1
        transportCheckedURICount = 0
        lastGeometryRestartSize = nil
        cancelScheduledRetry()
        teardown.setTimer(nil)
        stopVLC()
        engine = .avPlayer
        replacePlayer() // disposes the old (possibly wedged) player off-main
        currentStream = nil
        currentURL = nil
        currentTSURL = nil
        currentHLSAvailable = true
        stallRecoveryEvents = []
        // A later retry()/play() must start from a clean recovery history —
        // stale attempt counts would inherit the previous stream's backoff.
        reconnectAttempts = 0
        lastReconnectAt = nil
        waitingSince = nil
        frozenSeconds = 0
        attemptedSeekRecovery = false
        state = .idle
    }

    // MARK: - Playback plumbing

    private func startPlayback(_ stream: LiveStream, url: URL, as initialState: State) {
        playbackGeneration &+= 1
        transportCheckedURICount = 0
        settings = settingsStore.load()
        stopVLC()
        engine = .avPlayer
        replacePlayer()
        currentStream = stream
        currentURL = url
        state = initialState
        lastObservedTime = .zero
        frozenSeconds = 0
        waitingSince = Date()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = settings.forwardBufferSeconds
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = CMTime(seconds: settings.liveEdgeOffsetSeconds, preferredTimescale: 1)

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        videoOutput = output
        attemptedSeekRecovery = false

        observe(item)
        player.replaceCurrentItem(with: item)
        // Fast start begins as soon as the first frames decode instead of
        // waiting for a "safe" buffer — shaves seconds off starts/reconnects.
        if settings.fastStart {
            player.playImmediately(atRate: 1.0)
        } else {
            player.play()
        }
        startWatchdog()
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = Self.friendlyPlaybackMessage(for: item.error)
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.state = .playing
                    self.adaptLiveOffsetToWindow(of: item)
                case .failed:
                    self.handleItemFailure(item.error, fallbackMessage: message)
                default:
                    break
                }
            }
        }

        // timeControlStatus KVO only fires on *changes* — a stall can begin and
        // end while it sits at .playing, which would leave the buffering
        // overlay stuck. keepUp flips back to true as soon as data flows again.
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let keepUp = item.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item, keepUp else { return }
                if self.state == .buffering || self.state == .loading || self.state == .reconnecting {
                    self.state = .playing
                }
            }
        }

        removeNotificationObservers()
        teardown.store(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.state = .buffering
                if self.waitingSince == nil {
                    self.waitingSince = Date()
                }
                // Nudge playback; AVPlayer resumes once data flows again.
                self.player.playImmediately(atRate: 1.0)
            }
        })
        // Corrupted or truncated live segments can make the item "end".
        teardown.store(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.reconnectOrFail("The stream stopped unexpectedly.")
            }
        })
    }

    private func removeNotificationObservers() {
        teardown.removeObservers()
    }

    /// Xtream panels keep a tiny live window (often ~30s of segments). A
    /// cushion deeper than a third of that window parks playback near the
    /// window's trailing edge, where any hiccup falls out of the playlist and
    /// stalls. Cap the configured offset once the window size is known —
    /// stall-recovery seeks (automaticallyPreservesTimeOffsetFromLive) then
    /// re-anchor to the capped offset.
    private func adaptLiveOffsetToWindow(of item: AVPlayerItem) {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let window = CMTimeGetSeconds(range.duration)
        guard window.isFinite, window > 0 else { return }
        let cap = max(4, window / 3)
        if settings.liveEdgeOffsetSeconds > cap {
            item.configuredTimeOffsetFromLive = CMTime(seconds: cap, preferredTimescale: 1)
        }
    }

    // MARK: - Reconnect watchdog

    private func startWatchdog() {
        // setTimer invalidates the previous watchdog.
        teardown.setTimer(Timer.scheduledTimer(withTimeInterval: settings.watchdogIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchdogTick()
            }
        })
    }

    func watchdogTick() {
        if engine == .avPlayer, enforcePlaybackTransport() { return }
        guard engine == .avPlayer else { return } // VLC self-recovers via delegate
        guard currentStream != nil, state != .idle else { return }
        if case .failed = state { return }

        switch player.timeControlStatus {
        case .playing:
            // The engine claims it's playing — verify both the clock and the
            // video track. Audio keeps the clock moving even when video froze.
            let now = player.currentTime()
            let clockAdvanced = CMTimeCompare(now, lastObservedTime) != 0
            lastObservedTime = now
            let videoHealthy = hasFreshVideoFrame()

            if clockAdvanced && videoHealthy {
                frozenSeconds = 0
                waitingSince = nil
                noteHealthyPlayback() // healthy again: reset budget, kill pending retry
                attemptedSeekRecovery = false
                if state == .buffering || state == .loading || state == .reconnecting {
                    state = .playing // healthy: clear any stale overlay
                }
            } else {
                frozenSeconds += settings.watchdogIntervalSeconds
                if frozenSeconds >= settings.frozenTimeoutSeconds {
                    frozenSeconds = 0
                    noteStallRecovery()
                    guard engine == .avPlayer else { break } // churn-switched to VLC
                    if !attemptedSeekRecovery {
                        // Cheap first: jump back to the live edge, which
                        // usually unsticks the video decoder without the
                        // black-screen cost of a full reconnect.
                        attemptedSeekRecovery = true
                        seekTowardLiveEdge()
                    } else {
                        reconnect()
                    }
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            escalateWaitRecovery()
        case .paused:
            // A user pause happens from the .playing state. If we're stuck in
            // buffering/loading/reconnecting and the engine paused itself, it
            // gave up (corrupted segments, dead stream) — recover.
            if state == .buffering || state == .loading || state == .reconnecting {
                escalateWaitRecovery()
            } else {
                waitingSince = nil // genuine user pause; don't fight it
            }
        @unknown default:
            break
        }
    }

    /// Stuck waiting/paused past the timeout: try the cheap seek to the live
    /// edge first (a stalled playhead often just fell out of the panel's
    /// short live window); reconnect only if that already failed.
    private func escalateWaitRecovery() {
        guard let waitingSince else {
            self.waitingSince = Date()
            return
        }
        guard Date().timeIntervalSince(waitingSince) >= settings.waitingTimeoutSeconds else { return }
        self.waitingSince = Date() // restart the clock for the next escalation
        noteStallRecovery()
        guard engine == .avPlayer else { return } // churn-switched to VLC
        if !attemptedSeekRecovery {
            attemptedSeekRecovery = true
            seekTowardLiveEdge()
        } else {
            reconnect()
        }
    }

    /// Counts AVPlayer stall recoveries. Three within two minutes means the
    /// panel's HLS is too broken for AVPlayer — switch this channel to the
    /// raw MPEG-TS stream through VLC (the strategy every other IPTV player
    /// uses), silently and for the rest of the session.
    private func noteStallRecovery() {
        guard engine == .avPlayer, settings.preferredEngine == .auto else { return }
        let now = Date()
        stallRecoveryEvents = stallRecoveryEvents.filter { now.timeIntervalSince($0) < 120 }
        stallRecoveryEvents.append(now)
        guard stallRecoveryEvents.count >= 3 else { return }
        #if canImport(VLCKitSPM)
        guard let currentStream, let url = currentVLCURL else { return }
        stallRecoveryEvents = []
        vlcOnlyStreams.insert(currentStream.id)
        startVLCPlayback(currentStream, url: url, as: .reconnecting)
        #endif
    }

    /// True when a video frame newer than the last check is available.
    /// Audio-only channels (no presentation size) always count as healthy.
    private func hasFreshVideoFrame() -> Bool {
        guard let item = player.currentItem, let output = videoOutput else { return true }
        guard item.presentationSize != .zero else { return true }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return false }
        // Consume the buffer so the next tick reports fresh data only.
        _ = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        return true
    }

    private func seekTowardLiveEdge() {
        guard player.currentItem != nil else {
            reconnect()
            return
        }
        // Positive infinity means "the live edge" for live items. Async, and —
        // unlike querying seekableTimeRanges — it can't block the main thread
        // on a wedged item.
        player.seek(to: .positiveInfinity) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.playImmediately(atRate: 1.0)
            }
        }
    }

    /// Tears the item down and reopens the stream URL — the panel issues a
    /// fresh playback token on every connection. Live streams never give up:
    /// after a burst of fast retries it backs off but keeps trying silently,
    /// so a temporarily-dropped channel resumes on its own with no prompt.
    func reconnect() {
        guard let currentStream, let currentURL else { return }

        // Immediate for the first few attempts, then a capped backoff. Only
        // *executed* attempts count — a suppressed call schedules its own
        // cancellable retry instead of inflating the counter at whatever
        // cadence the caller happens to have (the VLC engine has no watchdog
        // at all, so nothing else would re-drive the backoff).
        let nextAttempt = reconnectAttempts + 1
        let backoff: TimeInterval = nextAttempt <= settings.maxReconnectAttempts
            ? 0
            : min(Double(nextAttempt - settings.maxReconnectAttempts) * 3, 15)
        let currentTime = now()
        if backoff > 0, let last = lastReconnectAt, currentTime.timeIntervalSince(last) < backoff {
            state = .reconnecting
            scheduleRetry(after: backoff - currentTime.timeIntervalSince(last))
            return
        }
        reconnectAttempts = nextAttempt
        lastReconnectAt = currentTime
        if let reconnectStartOverride {
            playbackGeneration &+= 1
            reconnectStartOverride(currentStream, currentURL)
            return
        }

        #if canImport(VLCKitSPM)
        if engine == .vlc {
            startVLCPlayback(currentStream, url: currentTSURL ?? currentURL, as: .reconnecting)
            return
        }
        #endif
        startPlayback(currentStream, url: currentURL, as: .reconnecting)
    }

    /// One pending retry at most: fires after `delay`, re-enters `reconnect()`
    /// only if this playback session is still current. Weakly held across the
    /// sleep, so a pending retry never pins the view model.
    private func scheduleRetry(after delay: TimeInterval) {
        guard reconnectRetryTask == nil else { return }
        let generation = playbackGeneration
        reconnectRetryTask = Task { [weak self] in
            guard let sleep = self?.retrySleep else { return }
            try? await sleep(delay)
            guard let self else { return }
            self.reconnectRetryTask = nil
            guard !Task.isCancelled, self.playbackGeneration == generation else { return }
            self.reconnect()
        }
    }

    private func cancelScheduledRetry() {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
    }

    /// Healthy progress observed (frames flowing, or the player reports
    /// playing): the recovery history resets AND any pending scheduled retry
    /// dies — a stream that recovered before its backoff delay expired must
    /// not be restarted by the sleeping task (its generation is still valid).
    func noteHealthyPlayback() {
        cancelScheduledRetry()
        reconnectAttempts = 0
        lastReconnectAt = nil
    }

    /// AVPlayer item failed: codec problems fall back to the VLC engine
    /// (which decodes MP2/interlaced via FFmpeg); anything else goes through
    /// the normal reconnect budget.
    private func handleItemFailure(_ error: Error?, fallbackMessage: String) {
        if Self.isCodecError(error), let currentStream {
            vlcOnlyStreams.insert(currentStream.id)
            #if canImport(VLCKitSPM)
            if let currentURL {
                reconnectAttempts = 0
                startVLCPlayback(currentStream, url: currentTSURL ?? currentURL, as: .loading)
                return
            }
            #endif
        }
        reconnectOrFail(fallbackMessage)
    }

    /// 'fmt?' and friends — the stream's codec can't be decoded here.
    private nonisolated static func isCodecError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        if nsError.domain == "CoreMediaErrorDomain" {
            return nsError.code == 1718449215 || nsError.code == -12718
        }
        return false
    }

    /// Translates opaque CoreMedia errors into something actionable.
    private nonisolated static func friendlyPlaybackMessage(for error: Error?) -> String {
        guard let error else { return "This channel could not be played." }
        let nsError = error as NSError
        // 'fmt?' — the stream uses a codec this device can't decode
        // (typically MP2 audio or interlaced video from IPTV panels).
        if nsError.domain == "CoreMediaErrorDomain" && nsError.code == 1718449215 {
            return "This channel uses a video/audio format not supported on this device."
        }
        return nsError.localizedDescription
    }

    /// A live stream that drops is always recoverable — keep reconnecting
    /// silently. Only surface a failure when there is genuinely nothing to
    /// reconnect to (no stream/URL, or a codec even VLC can't decode).
    private func reconnectOrFail(_ message: String) {
        if currentStream != nil, currentURL != nil {
            reconnect()
        } else {
            state = .failed(message)
        }
    }

    // MARK: - VLC fallback engine

    private func stopVLC() {
        #if canImport(VLCKitSPM)
        vlcPlayer?.stop()
        vlcPlayer?.delegate = nil
        vlcPlayer = nil
        #endif
    }

    #if canImport(VLCKitSPM)
    private func startVLCPlayback(_ stream: LiveStream, url: URL, as initialState: State) {
        playbackGeneration &+= 1
        settings = settingsStore.load()
        teardown.setTimer(nil)
        stopVLC()
        replacePlayer() // park the AVPlayer

        engine = .vlc
        currentStream = stream
        // Deliberately NOT overwriting currentURL: it keeps the original HLS
        // identity so retry() and an AVPlayer reconnect recover the right
        // stream — `url` here is usually the raw TS variant.
        state = initialState

        let media = VLCMedia(url: url)
        // The panel 403s non-Apple user agents (VLC's default is rejected).
        media.addOption(":http-user-agent=AppleCoreMedia/1.0.0")
        media.addOption(":http-reconnect=true")
        // 3s jitter buffer: quick zapping, stable playback. (Deriving it
        // from liveEdgeOffset made VLC pre-buffer for many seconds.)
        media.addOption(":network-caching=3000")

        let player = VLCMediaPlayer()
        player.media = media
        player.delegate = vlcProxy
        vlcPlayer = player
        player.play()
    }

    /// True while a session is actually running — the only states from which
    /// engine events may drive recovery.
    private var isInActivePlayback: Bool {
        switch state {
        case .loading, .playing, .buffering, .reconnecting: return true
        case .idle, .failed: return false
        }
    }

    func vlcStateChanged(_ vlcState: VLCMediaPlayerState, fromPlayerID playerID: ObjectIdentifier) {
        // Identity first: a replaced player's late events must never drive
        // the current session (the AVPlayer path guards with
        // `player.currentItem === item`; this is the VLC equivalent).
        guard let vlcPlayer, ObjectIdentifier(vlcPlayer) == playerID else { return }
        guard engine == .vlc else { return }
        switch vlcState {
        case .opening, .buffering:
            // VLC emits .buffering constantly during healthy playback —
            // never downgrade from .playing on it. Real progress is signalled
            // by vlcTimeAdvanced().
            break
        case .playing, .esAdded:
            state = .playing
            noteHealthyPlayback()
        case .paused:
            break // user pause via future controls; don't fight it
        case .error:
            guard isInActivePlayback else { return }
            reconnectOrFail("This channel could not be played (VLC engine).")
        case .stopped, .ended:
            // Live streams shouldn't end — treat as a dropped connection from
            // ANY active state: a stream that stops while still opening or
            // reconnecting was previously left stuck forever.
            if isInActivePlayback {
                reconnect()
            }
        @unknown default:
            break
        }
    }

    /// Orientation changed: VLC's GL output sizes its buffers off the main
    /// thread and often keeps the old geometry (small video in a black
    /// frame). Restarting the playback creates a correctly-sized vout.
    /// Reported from the video surface views on layout passes.
    func noteVideoSurfaceSize(_ size: CGSize) {
        currentSurfaceSize = size
    }

    /// Whether a restart is worth a new connection: >1pt in either dimension.
    nonisolated static func geometryMateriallyChanged(from last: CGSize?, to current: CGSize) -> Bool {
        guard let last else { return true }
        return abs(last.width - current.width) > 1 || abs(last.height - current.height) > 1
    }

    func videoSurfaceGeometryChanged() {
        guard engine == .vlc, let currentStream, let currentURL else { return }
        // A restart is a new provider connection — skip when the surface size
        // didn't materially change (chrome toggles with identical bounds).
        guard Self.geometryMateriallyChanged(from: lastGeometryRestartSize, to: currentSurfaceSize) else { return }
        lastGeometryRestartSize = currentSurfaceSize
        startVLCPlayback(currentStream, url: currentVLCURL ?? currentURL, as: .buffering)
    }

    /// VLC's playback clock advanced — frames are flowing.
    func vlcTimeAdvanced(fromPlayerID playerID: ObjectIdentifier) {
        guard let vlcPlayer, ObjectIdentifier(vlcPlayer) == playerID else { return }
        guard engine == .vlc, state != .playing else { return }
        if case .failed = state { return }
        state = .playing
        noteHealthyPlayback()
    }
    #endif
}

#if canImport(VLCKitSPM)
/// Bridges VLC's ObjC delegate onto the MainActor view model.
private final class VLCDelegateProxy: NSObject, VLCMediaPlayerDelegate {
    weak var owner: PlayerViewModel?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        let state = player.state
        // ObjectIdentifier travels instead of the (non-Sendable) player: the
        // owner compares it against its current instance, so a dying player's
        // events can't cross into the replacement's session.
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak owner] in
            owner?.vlcStateChanged(state, fromPlayerID: playerID)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak owner] in
            owner?.vlcTimeAdvanced(fromPlayerID: playerID)
        }
    }
}
#endif
