import Foundation

/// Persists the user's favorite channels, scoped per account so switching
/// providers doesn't mix stream IDs. UserDefaults-backed preference data.
public struct FavoritesStore {
    private let storage: KeyValueStorage
    private let key: String

    public init(account: Account, storage: KeyValueStorage = SyncedStorage.shared) {
        self.storage = storage
        self.key = "favorites.\(account.host.absoluteString).\(account.username)"
    }

    public func load() -> Set<StreamID> {
        let raw = storage.array(forKey: key) as? [Int] ?? []
        return Set(raw.map { StreamID($0) })
    }

    public func save(_ favorites: Set<StreamID>) {
        storage.set(favorites.map(\.rawValue).sorted(), forKey: key)
    }
}
