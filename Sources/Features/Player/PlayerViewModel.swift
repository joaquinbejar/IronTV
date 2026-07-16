import AVKit
import Combine
import Foundation
import QuartzCore

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
    func play(_ stream: LiveStream, url: URL) {
        reconnectAttempts = 0
        startPlayback(stream, url: url, as: .loading)
    }

    func retry() {
        guard let currentStream, let currentURL else { return }
        play(currentStream, url: currentURL)
    }

    /// Realigns audio/video clocks by jumping to the live edge — the manual
    /// fix for A/V drift accumulated from sloppy panel transcodes.
    func resyncToLive() {
        guard currentStream != nil else { return }
        seekTowardLiveEdge()
    }

    func fail(_ error: Error) {
        let playbackError = error as? PlaybackError ?? .itemFailed(error.localizedDescription)
        state = .failed(playbackError.errorDescription ?? "Playback failed.")
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        replacePlayer() // disposes the old (possibly wedged) player off-main
        currentStream = nil
        currentURL = nil
        state = .idle
    }

    // MARK: - Playback plumbing

    private func startPlayback(_ stream: LiveStream, url: URL, as initialState: State) {
        settings = settingsStore.load()
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
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.state = .playing
                case .failed:
                    self.reconnectOrFail(message ?? "This channel could not be played.")
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
        if !attemptedSeekRecovery {
            attemptedSeekRecovery = true
            seekTowardLiveEdge()
        } else {
            reconnect()
        }
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
    /// fresh playback token on every connection.
    private func reconnect() {
        guard let currentStream, let currentURL else { return }
        reconnectAttempts += 1
        guard reconnectAttempts <= settings.maxReconnectAttempts else {
            watchdog?.invalidate()
            watchdog = nil
            state = .failed("Lost connection to the stream. Press Retry to reconnect.")
            return
        }
        startPlayback(currentStream, url: currentURL, as: .reconnecting)
    }

    private func reconnectOrFail(_ message: String) {
        if reconnectAttempts < settings.maxReconnectAttempts, currentStream != nil, currentURL != nil {
            reconnect()
        } else {
            state = .failed(message)
        }
    }

    deinit {
        watchdog?.invalidate()
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }
}
