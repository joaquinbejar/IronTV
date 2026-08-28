import Foundation

/// Persists `PlaybackSettings` in UserDefaults; absent keys fall back to defaults.
public struct PlaybackSettingsStore {
    private let storage: KeyValueStorage

    private enum Key {
        static let forwardBuffer = "playback.forwardBufferSeconds"
        static let liveEdgeOffset = "playback.liveEdgeOffsetSeconds"
        static let waitingTimeout = "playback.waitingTimeoutSeconds"
        static let frozenTimeout = "playback.frozenTimeoutSeconds"
        static let maxReconnects = "playback.maxReconnectAttempts"
        static let watchdogInterval = "playback.watchdogIntervalSeconds"
        static let fastStart = "playback.fastStart"
        static let apiTimeout = "playback.apiTimeoutSeconds"
        static let engine = "playback.preferredEngine"
        static let playlistCacheHours = "playback.playlistCacheHours"
    }

    public init(storage: KeyValueStorage = SyncedStorage.shared) {
        self.storage = storage
    }

    /// Always returns validated values: UserDefaults and iCloud KVS can carry
    /// out-of-range, non-finite, or legacy data (other devices, other app
    /// versions), and every consumer feeds these straight into timers, CMTime
    /// and retry math. Normalized values are deliberately NOT written back —
    /// rewriting on load would ping-pong with a remote device holding the
    /// hostile value.
    public func load() -> PlaybackSettings {
        let fallback = PlaybackSettings.default
        return raw(fallback: fallback).validated()
    }

    private func raw(fallback: PlaybackSettings) -> PlaybackSettings {
        PlaybackSettings(
            forwardBufferSeconds: double(Key.forwardBuffer) ?? fallback.forwardBufferSeconds,
            liveEdgeOffsetSeconds: double(Key.liveEdgeOffset) ?? fallback.liveEdgeOffsetSeconds,
            waitingTimeoutSeconds: double(Key.waitingTimeout) ?? fallback.waitingTimeoutSeconds,
            frozenTimeoutSeconds: double(Key.frozenTimeout) ?? fallback.frozenTimeoutSeconds,
            maxReconnectAttempts: (storage.object(forKey: Key.maxReconnects) as? NSNumber)?.intValue ?? fallback.maxReconnectAttempts,
            watchdogIntervalSeconds: double(Key.watchdogInterval) ?? fallback.watchdogIntervalSeconds,
            fastStart: (storage.object(forKey: Key.fastStart) as? Bool) ?? fallback.fastStart,
            apiTimeoutSeconds: double(Key.apiTimeout) ?? fallback.apiTimeoutSeconds,
            preferredEngine: (storage.object(forKey: Key.engine) as? String)
                .flatMap(PlaybackEngineOption.init(rawValue:)) ?? fallback.preferredEngine,
            playlistCacheHours: double(Key.playlistCacheHours) ?? fallback.playlistCacheHours
        )
    }

    public func save(_ settings: PlaybackSettings) {
        storage.set(settings.forwardBufferSeconds, forKey: Key.forwardBuffer)
        storage.set(settings.liveEdgeOffsetSeconds, forKey: Key.liveEdgeOffset)
        storage.set(settings.waitingTimeoutSeconds, forKey: Key.waitingTimeout)
        storage.set(settings.frozenTimeoutSeconds, forKey: Key.frozenTimeout)
        storage.set(settings.maxReconnectAttempts, forKey: Key.maxReconnects)
        storage.set(settings.watchdogIntervalSeconds, forKey: Key.watchdogInterval)
        storage.set(settings.fastStart, forKey: Key.fastStart)
        storage.set(settings.apiTimeoutSeconds, forKey: Key.apiTimeout)
        storage.set(settings.preferredEngine.rawValue, forKey: Key.engine)
        storage.set(settings.playlistCacheHours, forKey: Key.playlistCacheHours)
    }

    public func reset() {
        [Key.forwardBuffer, Key.liveEdgeOffset, Key.waitingTimeout, Key.frozenTimeout,
         Key.maxReconnects, Key.watchdogInterval, Key.fastStart, Key.apiTimeout, Key.engine,
         Key.playlistCacheHours]
            .forEach(storage.removeObject(forKey:))
    }

    /// NSNumber-based coercion: legacy versions, other platforms, or iCloud
    /// can store an Int where we expect a Double (and vice versa) — those
    /// values must load and clamp, not silently reset to defaults.
    private func double(_ key: String) -> Double? {
        (storage.object(forKey: key) as? NSNumber)?.doubleValue
    }
}
