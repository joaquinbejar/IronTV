import Foundation

/// Remembers the last watched category/channel so playback can resume on the
/// next launch. UserDefaults-backed — this is preference data, not a secret.
public struct LastChannelStore {
    private let storage: KeyValueStorage
    private let categoryKey = "lastCategoryID"
    private let streamKey = "lastStreamID"
    // Sentinels for the non-category selections; panel category IDs are positive.
    private let allSentinel = -1
    private let favoritesSentinel = -2

    public init(storage: KeyValueStorage = SyncedStorage.shared) {
        self.storage = storage
    }

    public var lastCategory: CategorySelection? {
        get {
            guard let raw = storage.object(forKey: categoryKey) as? Int else { return nil }
            switch raw {
            case allSentinel: return .all
            case favoritesSentinel: return .favorites
            default: return .category(CategoryID(raw))
            }
        }
        nonmutating set {
            switch newValue {
            case .all:
                storage.set(allSentinel, forKey: categoryKey)
            case .favorites:
                storage.set(favoritesSentinel, forKey: categoryKey)
            case .category(let id):
                storage.set(id.rawValue, forKey: categoryKey)
            case nil:
                storage.removeObject(forKey: categoryKey)
            }
        }
    }

    public var lastStreamID: StreamID? {
        get { (storage.object(forKey: streamKey) as? Int).map { StreamID($0) } }
        nonmutating set {
            if let newValue {
                storage.set(newValue.rawValue, forKey: streamKey)
            } else {
                storage.removeObject(forKey: streamKey)
            }
        }
    }

    public func clear() {
        lastCategory = nil
        lastStreamID = nil
    }
}
