import Foundation

/// User-tunable playback behavior. All durations in seconds.
public struct PlaybackSettings: Equatable, Sendable {
    /// How much media the player tries to keep buffered ahead of playback.
    public var forwardBufferSeconds: TimeInterval
    /// How far behind the live edge playback starts — the stall cushion.
    public var liveEdgeOffsetSeconds: TimeInterval
    /// Reconnect after this long stuck buffering.
    public var waitingTimeoutSeconds: TimeInterval
    /// Reconnect after this long of frozen video while nominally playing.
    public var frozenTimeoutSeconds: TimeInterval
    /// Consecutive automatic reconnects before giving up.
    public var maxReconnectAttempts: Int
    /// How often the playback watchdog checks stream health.
    public var watchdogIntervalSeconds: TimeInterval
    /// Start playback as soon as frames decode instead of waiting for a safe
    /// buffer — faster starts/reconnects, may stutter on weak connections.
    public var fastStart: Bool
    /// Timeout for JSON API requests (categories, channel lists, validation).
    public var apiTimeoutSeconds: TimeInterval

    public init(
        forwardBufferSeconds: TimeInterval,
        liveEdgeOffsetSeconds: TimeInterval,
        waitingTimeoutSeconds: TimeInterval,
        frozenTimeoutSeconds: TimeInterval,
        maxReconnectAttempts: Int,
        watchdogIntervalSeconds: TimeInterval,
        fastStart: Bool,
        apiTimeoutSeconds: TimeInterval
    ) {
        self.forwardBufferSeconds = forwardBufferSeconds
        self.liveEdgeOffsetSeconds = liveEdgeOffsetSeconds
        self.waitingTimeoutSeconds = waitingTimeoutSeconds
        self.frozenTimeoutSeconds = frozenTimeoutSeconds
        self.maxReconnectAttempts = maxReconnectAttempts
        self.watchdogIntervalSeconds = watchdogIntervalSeconds
        self.fastStart = fastStart
        self.apiTimeoutSeconds = apiTimeoutSeconds
    }

    public static let `default` = PlaybackSettings(
        forwardBufferSeconds: 30,
        liveEdgeOffsetSeconds: 20,
        waitingTimeoutSeconds: 8,
        frozenTimeoutSeconds: 6,
        maxReconnectAttempts: 5,
        watchdogIntervalSeconds: 2,
        fastStart: true,
        apiTimeoutSeconds: 30
    )
}
