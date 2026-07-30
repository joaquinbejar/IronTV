import Foundation

/// Copies per-account preferences to a new account namespace when a saved
/// account changes identity for a reason invisible to the user — today, the
/// verified http→https transport upgrade. `AccountIdentity.namespace` embeds
/// the scheme, so without this the upgraded account would start with empty
/// favorites and no last channel.
public enum AccountPreferenceMigrator {
    /// Copies favorites and the last category/stream from `old`'s namespace to
    /// `new`'s, only where the destination has nothing yet — a value already
    /// stored under the new namespace is never clobbered.
    public static func migrate(from old: Account, to new: Account, storage: KeyValueStorage = SyncedStorage.shared) {
        let newFavorites = FavoritesStore(account: new, storage: storage)
        if newFavorites.load().isEmpty {
            let favorites = FavoritesStore(account: old, storage: storage).load()
            if !favorites.isEmpty {
                newFavorites.save(favorites)
            }
        }

        let oldChannel = LastChannelStore(identity: old.identity, storage: storage)
        let newChannel = LastChannelStore(identity: new.identity, storage: storage)
        if newChannel.lastCategory == nil, let category = oldChannel.lastCategory {
            newChannel.lastCategory = category
        }
        if newChannel.lastStreamID == nil, let stream = oldChannel.lastStreamID {
            newChannel.lastStreamID = stream
        }
    }
}
