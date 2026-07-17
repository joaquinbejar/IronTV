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

    init(settingsStore: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.settingsStore = settingsStore
        configureTimeControlObservation()
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

    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var lastObservedTime: CMTime = .zero
    private var frozenSeconds: TimeInterval = 0
    private var waitingSince: Date?
    private var reconnectAttempts = 0
    private var lastReconnectAt: Date?
    /// Raw MPEG-TS variant of the current stream, for the VLC engine.
    private var currentTSURL: URL?
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

    private func configureTimeControlObservation() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.currentStream != nil else { return }
                switch status {
                case .playing:
                    self.state = .playing
                    self.waitingSince = nil
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
    func play(_ stream: LiveStream, url: URL, tsURL: URL? = nil) {
        reconnectAttempts = 0
        lastReconnectAt = nil
        stallRecoveryEvents = []
        currentTSURL = tsURL
        settings = settingsStore.load()
        #if canImport(VLCKitSPM)
        // Forced-VLC preference, or a channel this session already learned
        // needs VLC — skip the AVPlayer attempt entirely.
        let forceVLC = settings.preferredEngine == .vlc && !DemoMode.isActive
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
        play(currentStream, url: currentURL, tsURL: currentTSURL)
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
        watchdog?.invalidate()
        watchdog = nil
        stopVLC()
        engine = .avPlayer
        replacePlayer() // disposes the old (possibly wedged) player off-main
        currentStream = nil
        currentURL = nil
        currentTSURL = nil
        stallRecoveryEvents = []
        state = .idle
    }

    // MARK: - Playback plumbing

    private func startPlayback(_ stream: LiveStream, url: URL, as initialState: State) {
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
        notificationObservers.append(NotificationCenter.default.addObserver(
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
        notificationObservers.append(NotificationCenter.default.addObserver(
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
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
        notificationObservers = []
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
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: settings.watchdogIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
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
                reconnectAttempts = 0 // healthy again; reset the budget
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
    private func reconnect() {
        guard let currentStream, let currentURL else { return }
        reconnectAttempts += 1

        // Immediate for the first few attempts, then a capped backoff. The
        // watchdog keeps calling us; we no-op (staying in .reconnecting) until
        // enough time has passed for the next attempt.
        let backoff: TimeInterval = reconnectAttempts <= settings.maxReconnectAttempts
            ? 0
            : min(Double(reconnectAttempts - settings.maxReconnectAttempts) * 3, 15)
        let now = Date()
        if backoff > 0, let last = lastReconnectAt, now.timeIntervalSince(last) < backoff {
            state = .reconnecting
            return
        }
        lastReconnectAt = now

        #if canImport(VLCKitSPM)
        if engine == .vlc {
            startVLCPlayback(currentStream, url: currentTSURL ?? currentURL, as: .reconnecting)
            return
        }
        #endif
        startPlayback(currentStream, url: currentURL, as: .reconnecting)
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
    private static func isCodecError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        if nsError.domain == "CoreMediaErrorDomain" {
            return nsError.code == 1718449215 || nsError.code == -12718
        }
        return false
    }

    /// Translates opaque CoreMedia errors into something actionable.
    private static func friendlyPlaybackMessage(for error: Error?) -> String {
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

    deinit {
        watchdog?.invalidate()
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
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
        settings = settingsStore.load()
        watchdog?.invalidate()
        watchdog = nil
        stopVLC()
        replacePlayer() // park the AVPlayer

        engine = .vlc
        currentStream = stream
        currentURL = url
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

    fileprivate func vlcStateChanged(_ vlcState: VLCMediaPlayerState) {
        guard engine == .vlc else { return }
        switch vlcState {
        case .opening, .buffering:
            // VLC emits .buffering constantly during healthy playback —
            // never downgrade from .playing on it. Real progress is signalled
            // by vlcTimeAdvanced().
            break
        case .playing, .esAdded:
            state = .playing
        case .paused:
            break // user pause via future controls; don't fight it
        case .error:
            reconnectOrFail("This channel could not be played (VLC engine).")
        case .stopped, .ended:
            // Live streams shouldn't end — treat as a dropped connection.
            if state == .playing || state == .buffering {
                reconnect()
            }
        @unknown default:
            break
        }
    }

    /// Orientation changed: VLC's GL output sizes its buffers off the main
    /// thread and often keeps the old geometry (small video in a black
    /// frame). Restarting the playback creates a correctly-sized vout.
    func videoSurfaceGeometryChanged() {
        guard engine == .vlc, let currentStream, let currentURL else { return }
        startVLCPlayback(currentStream, url: currentVLCURL ?? currentURL, as: .buffering)
    }

    /// VLC's playback clock advanced — frames are flowing.
    fileprivate func vlcTimeAdvanced() {
        guard engine == .vlc, state != .playing else { return }
        if case .failed = state { return }
        state = .playing
        reconnectAttempts = 0
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
        Task { @MainActor [weak owner] in
            owner?.vlcStateChanged(state)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak owner] in
            owner?.vlcTimeAdvanced()
        }
    }
}
#endif
