import Combine
import Foundation

/// State for the Playback settings screen. Exists because iCloud KVS merges
/// playback settings per field: while the screen is open, another device can
/// change one field, and a view that only loaded on appear would write its
/// stale snapshot back on the next local edit — silently undoing the remote
/// change. This model adopts remote changes as they arrive and persists only
/// when the on-screen value actually differs from what is stored.
@MainActor
final class PlaybackSettingsModel: ObservableObject {
    @Published var settings: PlaybackSettings

    private let store: PlaybackSettingsStore
    private let teardown = TeardownBag()

    init(store: PlaybackSettingsStore = PlaybackSettingsStore()) {
        self.store = store
        self.settings = store.load()
        teardown.store(NotificationCenter.default.addObserver(
            forName: SyncedStorage.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changed = notification.userInfo?[SyncedStorage.changedKeysUserInfoKey] as? [String] ?? []
            guard changed.contains(where: { $0.hasPrefix("playback.") }) else { return }
            // Posted on the main queue by SyncedStorage — assert, don't hop.
            MainActor.assumeIsolated {
                self?.adoptRemoteChanges()
            }
        })
    }

    /// Remote values replace the on-screen snapshot, so the next local edit
    /// persists a fresh snapshot instead of undoing another device's change.
    private func adoptRemoteChanges() {
        settings = store.load()
    }

    /// Persists only when the on-screen value differs from what is stored.
    /// The equality guard is what breaks the save loop: adopting a remote
    /// change updates `settings` to exactly the stored values, so the view's
    /// onChange round-trip becomes a no-op instead of nine writes.
    func persist() {
        guard settings != store.load() else { return }
        store.save(settings)
    }

    func reload() {
        settings = store.load()
    }

    func restoreDefaults() {
        store.reset()
        settings = store.load()
    }
}
