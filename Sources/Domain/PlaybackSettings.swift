import Foundation

/// Which playback engine handles panel streams.
public enum PlaybackEngineOption: String, CaseIterable, Sendable {
    /// AVPlayer (HLS) first; channels that stall repeatedly or use codecs
    /// AVPlayer can't decode switch to VLC (MPEG-TS) automatically.
    case auto
    /// Always AVPlayer over HLS (VLC still rescues codec failures).
    case avplayer
    /// Always VLC over the raw MPEG-TS stream — what most IPTV apps do.
    case vlc
}

/// User-tunable playback behavior. All durations in seconds.
public struct PlaybackSettings: Equatable, Sendable {
    /// How much media the player tries to keep buffered ahead of playback.
    public var forwardBufferSeconds: TimeInterval
    /// How far behind the live edge playback starts — the stall cushion.
    /// Capped at runtime to a third of the panel's live window, which on
    /// typical Xtream panels is only ~30s deep.
    public var liveEdgeOffsetSeconds: TimeInterval
    /// Reconnect after this long stuck buffering.
    public var waitingTimeoutSeconds: TimeInterval
    /// Reconnect after this long of frozen video while nominally playing.
    public var frozenTimeoutSeconds: TimeInterval
    /// Fast reconnects before switching to a slower retry cadence.
    public var maxReconnectAttempts: Int
    /// How often the playback watchdog checks stream health.
    public var watchdogIntervalSeconds: TimeInterval
    /// Start playback as soon as frames decode instead of waiting for a safe
    /// buffer — faster starts/reconnects, may stutter on weak connections.
    public var fastStart: Bool
    /// Timeout for JSON API requests (categories, channel lists, validation).
    public var apiTimeoutSeconds: TimeInterval
    /// Engine strategy for panel streams.
    public var preferredEngine: PlaybackEngineOption

    public init(
        forwardBufferSeconds: TimeInterval,
        liveEdgeOffsetSeconds: TimeInterval,
        waitingTimeoutSeconds: TimeInterval,
        frozenTimeoutSeconds: TimeInterval,
        maxReconnectAttempts: Int,
        watchdogIntervalSeconds: TimeInterval,
        fastStart: Bool,
        apiTimeoutSeconds: TimeInterval,
        preferredEngine: PlaybackEngineOption
    ) {
        self.forwardBufferSeconds = forwardBufferSeconds
        self.liveEdgeOffsetSeconds = liveEdgeOffsetSeconds
        self.waitingTimeoutSeconds = waitingTimeoutSeconds
        self.frozenTimeoutSeconds = frozenTimeoutSeconds
        self.maxReconnectAttempts = maxReconnectAttempts
        self.watchdogIntervalSeconds = watchdogIntervalSeconds
        self.fastStart = fastStart
        self.apiTimeoutSeconds = apiTimeoutSeconds
        self.preferredEngine = preferredEngine
    }

    public static let `default` = PlaybackSettings(
        forwardBufferSeconds: 30,
        liveEdgeOffsetSeconds: 10,
        waitingTimeoutSeconds: 8,
        frozenTimeoutSeconds: 6,
        maxReconnectAttempts: 5,
        watchdogIntervalSeconds: 2,
        fastStart: true,
        apiTimeoutSeconds: 30,
        preferredEngine: .auto
    )
}
