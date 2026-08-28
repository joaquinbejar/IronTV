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
    /// How long a downloaded playlist stays usable before the next catalog
    /// read re-fetches it. Only playlist-sourced accounts read this: an
    /// Xtream catalog is fetched per category and needs no such policy.
    /// Provider playlists reach tens of megabytes, so downloading on every
    /// launch is not acceptable on cellular; an explicit refresh always
    /// ignores this value.
    public var playlistCacheHours: TimeInterval

    public init(
        forwardBufferSeconds: TimeInterval,
        liveEdgeOffsetSeconds: TimeInterval,
        waitingTimeoutSeconds: TimeInterval,
        frozenTimeoutSeconds: TimeInterval,
        maxReconnectAttempts: Int,
        watchdogIntervalSeconds: TimeInterval,
        fastStart: Bool,
        apiTimeoutSeconds: TimeInterval,
        preferredEngine: PlaybackEngineOption,
        playlistCacheHours: TimeInterval = PlaybackSettings.defaultPlaylistCacheHours
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
        self.playlistCacheHours = playlistCacheHours
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
        preferredEngine: .auto,
        playlistCacheHours: PlaybackSettings.defaultPlaylistCacheHours
    )

    /// A day: long enough that opening the app is instant and cheap, short
    /// enough that a provider's weekly channel changes appear without the
    /// user having to know the refresh button exists.
    public static let defaultPlaylistCacheHours: TimeInterval = 24

    // MARK: - Constraints

    /// The single source of truth for valid ranges. The Settings UI derives
    /// its steppers from these, and ``validated()`` clamps into them — so the
    /// two can never drift apart, and no value outside them can reach a
    /// Timer, CMTime, URLRequest timeout, or retry calculation.
    public static let forwardBufferRange: ClosedRange<TimeInterval> = 5...120
    /// Zero means "always re-fetch", which is a legitimate choice for someone
    /// whose provider changes channels constantly.
    public static let playlistCacheHoursRange: ClosedRange<TimeInterval> = 0...168
    public static let liveEdgeOffsetRange: ClosedRange<TimeInterval> = 0...60
    public static let waitingTimeoutRange: ClosedRange<TimeInterval> = 2...60
    public static let frozenTimeoutRange: ClosedRange<TimeInterval> = 2...60
    /// Lower bound 1 guarantees the watchdog always makes progress — a zero
    /// or negative interval would create a run-loop-hot repeating timer and
    /// disable freeze detection.
    public static let watchdogIntervalRange: ClosedRange<TimeInterval> = 1...10
    public static let maxReconnectAttemptsRange: ClosedRange<Int> = 1...10
    public static let apiTimeoutRange: ClosedRange<TimeInterval> = 5...120

    /// Persisted values arrive from UserDefaults and iCloud KVS — other
    /// devices, other app versions, or hand-edited plists. Every numeric
    /// field is normalized: non-finite (NaN/±∞) falls back to the default,
    /// anything else clamps into its documented range. The engine already
    /// falls back at decode (`PlaybackEngineOption(rawValue:)`).
    public func validated() -> PlaybackSettings {
        PlaybackSettings(
            forwardBufferSeconds: Self.normalize(forwardBufferSeconds, into: Self.forwardBufferRange, default: Self.default.forwardBufferSeconds),
            liveEdgeOffsetSeconds: Self.normalize(liveEdgeOffsetSeconds, into: Self.liveEdgeOffsetRange, default: Self.default.liveEdgeOffsetSeconds),
            waitingTimeoutSeconds: Self.normalize(waitingTimeoutSeconds, into: Self.waitingTimeoutRange, default: Self.default.waitingTimeoutSeconds),
            frozenTimeoutSeconds: Self.normalize(frozenTimeoutSeconds, into: Self.frozenTimeoutRange, default: Self.default.frozenTimeoutSeconds),
            maxReconnectAttempts: min(max(maxReconnectAttempts, Self.maxReconnectAttemptsRange.lowerBound), Self.maxReconnectAttemptsRange.upperBound),
            watchdogIntervalSeconds: Self.normalize(watchdogIntervalSeconds, into: Self.watchdogIntervalRange, default: Self.default.watchdogIntervalSeconds),
            fastStart: fastStart,
            apiTimeoutSeconds: Self.normalize(apiTimeoutSeconds, into: Self.apiTimeoutRange, default: Self.default.apiTimeoutSeconds),
            preferredEngine: preferredEngine,
            playlistCacheHours: Self.normalize(playlistCacheHours, into: Self.playlistCacheHoursRange, default: Self.default.playlistCacheHours)
        )
    }

    private static func normalize(_ value: TimeInterval, into range: ClosedRange<TimeInterval>, default fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
