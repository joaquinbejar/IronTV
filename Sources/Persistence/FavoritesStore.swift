import Foundation

/// Persists the user's favorite channels, scoped per account so switching
/// providers doesn't mix stream IDs. UserDefaults-backed preference data.
public struct FavoritesStore {
    private let storage: KeyValueStorage
    /// Exposed so screens can tell whether an iCloud change touched favorites
    /// (see `SyncedStorage.didChangeExternallyNotification`).
    public let storageKey: String

    public init(account: Account, storage: KeyValueStorage = SyncedStorage.shared) {
        self.storage = storage
        // Same namespace the rest of the preference stores use. It resolves to
        // the key shipped before AccountIdentity existed, so favorites already
        // synced to iCloud keep loading — see FavoritesStoreTests.
        self.storageKey = "favorites.\(account.identity.namespace)"
    }

    public func load() -> Set<StreamID> {
        let raw = storage.array(forKey: storageKey) as? [Int] ?? []
        return Set(raw.map { StreamID($0) })
    }

    public func save(_ favorites: Set<StreamID>) {
        storage.set(favorites.map(\.rawValue).sorted(), forKey: storageKey)
    }
}
