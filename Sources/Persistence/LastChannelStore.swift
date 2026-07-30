import Foundation

/// Remembers the last watched category/channel so playback can resume on the
/// next launch. UserDefaults-backed — this is preference data, not a secret.
///
/// Scoped per account: two providers routinely reuse the same numeric category
/// and stream IDs, so a shared key lets one restore the other's selection and
/// play the wrong channel. Scoping is by ``AccountIdentity/namespace``, so
/// rotating a password keeps the user's place.
public struct LastChannelStore {
    private let storage: KeyValueStorage
    private let categoryKey: String
    private let streamKey: String
    // Sentinels for the non-category selections; panel category IDs are positive.
    private let allSentinel = -1
    private let favoritesSentinel = -2

    /// Keys used before last-channel state was account-scoped. Whatever sits
    /// under them belongs to whichever provider was configured at the time.
    private static let legacyCategoryKey = "lastCategoryID"
    private static let legacyStreamKey = "lastStreamID"

    public init(identity: AccountIdentity, storage: KeyValueStorage = SyncedStorage.shared) {
        self.storage = storage
        self.categoryKey = "\(Self.legacyCategoryKey).\(identity.namespace)"
        self.streamKey = "\(Self.legacyStreamKey).\(identity.namespace)"
        adoptLegacyValuesIfNeeded()
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

    /// One-time migration: the first account to construct a store inherits the
    /// pre-scoping selection, then the legacy keys are dropped so no second
    /// provider can restore the first one's category or stream.
    private func adoptLegacyValuesIfNeeded() {
        let legacyCategory = storage.object(forKey: Self.legacyCategoryKey)
        let legacyStream = storage.object(forKey: Self.legacyStreamKey)
        guard legacyCategory != nil || legacyStream != nil else { return }

        if storage.object(forKey: categoryKey) == nil, let legacyCategory {
            storage.set(legacyCategory, forKey: categoryKey)
        }
        if storage.object(forKey: streamKey) == nil, let legacyStream {
            storage.set(legacyStream, forKey: streamKey)
        }
        Self.discardLegacyValues(in: storage)
    }

    /// Drops the pre-scoping keys without adopting them. Used at launch when no
    /// account is configured, so whichever account is added next cannot inherit
    /// a previous provider's selection.
    public static func discardLegacyValues(in storage: KeyValueStorage = SyncedStorage.shared) {
        storage.removeObject(forKey: legacyCategoryKey)
        storage.removeObject(forKey: legacyStreamKey)
    }
}
