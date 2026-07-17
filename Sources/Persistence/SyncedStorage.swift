import Foundation

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
public final class SyncedStorage: KeyValueStorage {
    public static let shared = SyncedStorage()

    private let defaults: UserDefaults
    /// nil until the iCloud KVS entitlement is provisioned — touching
    /// NSUbiquitousKeyValueStore without it logs "BUG IN CLIENT OF KVS"
    /// on every launch. Gated by the `IronTVCloudKVSEnabled` Info.plist flag.
    private let cloud: NSUbiquitousKeyValueStore?
    private var observer: NSObjectProtocol?

    public convenience init(defaults: UserDefaults = .standard) {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "IronTVCloudKVSEnabled") as? Bool ?? false
        self.init(defaults: defaults, cloud: enabled ? .default : nil)
    }

    public init(defaults: UserDefaults, cloud: NSUbiquitousKeyValueStore?) {
        self.defaults = defaults
        self.cloud = cloud

        guard let cloud else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            self?.applyExternalChanges(notification)
        }

        // Adopt whatever iCloud already has at startup (remote wins).
        cloud.synchronize()
        for (key, value) in cloud.dictionaryRepresentation {
            defaults.set(value, forKey: key)
        }
    }

    public func object(forKey defaultName: String) -> Any? {
        defaults.object(forKey: defaultName)
    }

    public func array(forKey defaultName: String) -> [Any]? {
        defaults.array(forKey: defaultName)
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        defaults.set(value, forKey: defaultName)
        cloud?.set(value, forKey: defaultName)
        cloud?.synchronize()
    }

    public func removeObject(forKey defaultName: String) {
        defaults.removeObject(forKey: defaultName)
        cloud?.removeObject(forKey: defaultName)
        cloud?.synchronize()
    }

    private func applyExternalChanges(_ notification: Notification) {
        guard let cloud else { return }
        let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        for key in changedKeys {
            if let value = cloud.object(forKey: key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
