import Foundation
import os

/// The NSUbiquitousKeyValueStore surface `SyncedStorage` uses, as a seam so
/// sync behavior — conflicts, change reasons, write batching — is
/// unit-testable without a provisioned iCloud container.
public protocol CloudKeyValueStore: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func object(forKey aKey: String) -> Any?
    func set(_ anObject: Any?, forKey aKey: String)
    func removeObject(forKey aKey: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStore {}

/// Minimal key-value surface the preference stores need. UserDefaults
/// satisfies it directly; SyncedStorage adds iCloud mirroring on top.
public protocol KeyValueStorage {
    func object(forKey defaultName: String) -> Any?
    func array(forKey defaultName: String) -> [Any]?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: KeyValueStorage {}

/// UserDefaults mirrored to iCloud's key-value store so playback settings,
/// favorites, and the last channel follow the user across devices.
///
/// Local UserDefaults stays the synchronous source of truth; writes are
/// pushed to `NSUbiquitousKeyValueStore`, and remote changes are folded back
/// in (remote wins). Without the iCloud KVS entitlement this degrades
/// gracefully to plain UserDefaults — mirroring is simply inert.
///
/// Isolation model (`@unchecked Sendable` justification): every stored
/// property is an immutable reference — `UserDefaults` and
/// `NSUbiquitousKeyValueStore` are documented thread-safe, and the observer
/// token lives in a locking ``TeardownBag``. The iCloud fold-in is serialized
/// on the main queue, and `didChangeExternallyNotification` is always posted
/// there.
public final class SyncedStorage: KeyValueStorage, @unchecked Sendable {
    public static let shared = SyncedStorage()

    /// Posted on the main queue after an iCloud-originated change has been
    /// folded into UserDefaults, so open screens can re-read their values.
    /// `userInfo[changedKeysUserInfoKey]` holds the affected keys.
    public static let didChangeExternallyNotification = Notification.Name("IronTVSyncedStorageDidChangeExternally")
    public static let changedKeysUserInfoKey = "changedKeys"

    private let defaults: UserDefaults
    /// nil until the iCloud KVS entitlement is provisioned — touching
    /// NSUbiquitousKeyValueStore without it logs "BUG IN CLIENT OF KVS"
    /// on every launch. Gated by the `IronTVCloudKVSEnabled` Info.plist flag.
    private let cloud: CloudKeyValueStore?
    private let teardown = TeardownBag()

    /// Sync diagnostics: change reasons and key counts only — never values,
    /// which can be account-scoped preference data.
    private static let logger = Logger(subsystem: "com.taunais.irontv", category: "kvs")

    public convenience init(defaults: UserDefaults = .standard) {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "IronTVCloudKVSEnabled") as? Bool ?? false
        self.init(defaults: defaults, cloud: enabled ? NSUbiquitousKeyValueStore.default : nil)
    }

    public init(defaults: UserDefaults, cloud: CloudKeyValueStore?) {
        self.defaults = defaults
        self.cloud = cloud

        guard let cloud else { return }

        teardown.store(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            self?.applyExternalChanges(notification)
        })

        // The one deliberate synchronize(): ask for the freshest server state
        // at startup, then adopt it (remote wins). Individual writes below
        // never force a sync — the system schedules uploads itself.
        cloud.synchronize()
        for (key, value) in cloud.dictionaryRepresentation {
            defaults.set(value, forKey: key)
        }
    }

    public func object(forKey defaultName: String) -> Any? {
        let local = defaults.object(forKey: defaultName)
        seedCloudIfEmpty(defaultName, local: local)
        return local
    }

    public func array(forKey defaultName: String) -> [Any]? {
        let local = defaults.array(forKey: defaultName)
        seedCloudIfEmpty(defaultName, local: local)
        return local
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        defaults.set(value, forKey: defaultName)
        // No synchronize(): forcing one per field turned a settings save
        // (nine keys) into a burst of sync requests. The documented KVS
        // lifecycle batches and uploads on its own schedule.
        cloud?.set(value, forKey: defaultName)
    }

    public func removeObject(forKey defaultName: String) {
        defaults.removeObject(forKey: defaultName)
        cloud?.removeObject(forKey: defaultName)
    }

    /// First launch after sync is enabled: iCloud holds nothing for a key this
    /// device already has. Push it up on read, so pre-sync favorites and
    /// settings reach the other devices without waiting for the user to change
    /// them. Reads are the only hook that names the keys the app actually uses
    /// — mirroring all of UserDefaults would ship unrelated state.
    private func seedCloudIfEmpty(_ key: String, local: Any?) {
        guard let cloud, let local, cloud.object(forKey: key) == nil else { return }
        cloud.set(local, forKey: key)
    }

    /// Conflict semantics, applied here for every synced value: per-key
    /// last-writer-wins, remote wins on arrival. Favorites are one key, so a
    /// remote list replaces ours wholesale (that's what makes removals
    /// propagate); playback settings are per-field keys, so devices can merge
    /// field-wise; last-channel state is per-key per account.
    private func applyExternalChanges(_ notification: Notification) {
        guard let cloud else { return }

        let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            // Nothing remote to adopt — our own writes were refused. The
            // system retries; local UserDefaults stays authoritative.
            Self.logger.warning("iCloud KVS quota violation — writes deferred by the system; local values remain authoritative.")
            return
        case NSUbiquitousKeyValueStoreAccountChange:
            Self.logger.notice("iCloud account changed — adopting the new account's key-value state.")
        case NSUbiquitousKeyValueStoreServerChange, NSUbiquitousKeyValueStoreInitialSyncChange:
            break
        default:
            break
        }

        var changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        if changedKeys.isEmpty {
            // Account change and initial sync can arrive without a per-key
            // list — adopt the whole remote state rather than staying on the
            // previous account's (or pre-sync) values. Other reasons with no
            // keys really mean nothing to do.
            guard reason == NSUbiquitousKeyValueStoreAccountChange
                || reason == NSUbiquitousKeyValueStoreInitialSyncChange else { return }
            changedKeys = Array(cloud.dictionaryRepresentation.keys)
            guard !changedKeys.isEmpty else { return }
        }
        Self.logger.debug("Adopting \(changedKeys.count, privacy: .public) remote key(s), reason \(reason.map(String.init) ?? "unknown", privacy: .public).")

        for key in changedKeys {
            if let value = cloud.object(forKey: key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        NotificationCenter.default.post(
            name: Self.didChangeExternallyNotification,
            object: self,
            userInfo: [Self.changedKeysUserInfoKey: changedKeys]
        )
    }

}
