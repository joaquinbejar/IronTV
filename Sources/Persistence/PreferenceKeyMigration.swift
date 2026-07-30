import Foundation

/// One-way, idempotent rename of a preference key: the pre-digest keys embed
/// `host.username` in plaintext, the current ones a privacy-preserving digest
/// (`AccountIdentity.storageNamespace`).
enum PreferenceKeyMigration {
    /// Copies the legacy value when the destination is still empty, then
    /// removes the legacy key. Going through the store means the copy and the
    /// removal mirror to iCloud too. Safe to re-run: if a legacy key
    /// reappears (an old app version pushed it to iCloud), the next store
    /// construction migrates it again — an existing destination value is
    /// never clobbered.
    static func migrate(_ legacyKey: String, to newKey: String, in storage: KeyValueStorage) {
        guard let value = storage.object(forKey: legacyKey) else { return }
        if storage.object(forKey: newKey) == nil {
            storage.set(value, forKey: newKey)
        }
        storage.removeObject(forKey: legacyKey)
    }
}
