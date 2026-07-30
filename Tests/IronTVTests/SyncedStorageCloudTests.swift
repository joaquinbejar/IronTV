import XCTest
@testable import IronTV

/// Sync behavior against a scripted cloud store: batching, first-sync
/// seeding, conflicts, deletions, and change reasons — no iCloud container.
@MainActor
final class SyncedStorageCloudTests: XCTestCase {

    private final class FakeCloudStore: CloudKeyValueStore, @unchecked Sendable {
        var values: [String: Any] = [:]
        private(set) var synchronizeCount = 0

        var dictionaryRepresentation: [String: Any] { values }
        func object(forKey aKey: String) -> Any? { values[aKey] }
        func set(_ anObject: Any?, forKey aKey: String) { values[aKey] = anObject }
        func removeObject(forKey aKey: String) { values.removeValue(forKey: aKey) }
        func synchronize() -> Bool {
            synchronizeCount += 1
            return true
        }

        /// Simulates the system's external-change notification. Posted on the
        /// main queue (the tests run there), so delivery is synchronous.
        func postExternalChange(keys: [String], reason: Int) {
            NotificationCenter.default.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: self,
                userInfo: [
                    NSUbiquitousKeyValueStoreChangedKeysKey: keys,
                    NSUbiquitousKeyValueStoreChangeReasonKey: reason,
                ]
            )
        }
    }

    private var defaults: UserDefaults!
    private let suiteName = "SyncedStorageCloudTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Counts our re-read notifications while keeping the token owned.
    private func observeFolds(into changed: NSMutableArray) -> TeardownBag {
        let bag = TeardownBag()
        bag.store(NotificationCenter.default.addObserver(
            forName: SyncedStorage.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { notification in
            let keys = notification.userInfo?[SyncedStorage.changedKeysUserInfoKey] as? [String] ?? []
            changed.add(keys)
        })
        return bag
    }

    func testInitAdoptsExistingCloudStateWithASingleSynchronize() {
        let cloud = FakeCloudStore()
        cloud.values = ["remote.key": 7]

        let storage = SyncedStorage(defaults: defaults, cloud: cloud)

        XCTAssertEqual(storage.object(forKey: "remote.key") as? Int, 7)
        XCTAssertEqual(cloud.synchronizeCount, 1, "exactly the deliberate startup synchronize")
    }

    func testBurstSettingsSaveForcesNoAdditionalSynchronize() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        var settings = PlaybackSettings.default
        settings.apiTimeoutSeconds = 42

        PlaybackSettingsStore(storage: storage).save(settings)

        XCTAssertEqual(cloud.synchronizeCount, 1, "nine field writes must not force nine syncs")
        XCTAssertEqual(cloud.values["playback.apiTimeoutSeconds"] as? Double, 42, "writes still mirror to the cloud")
    }

    func testFirstSyncSeedsALocalValueOnRead() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        defaults.set([1001], forKey: "favorites.v1.abc")

        _ = storage.array(forKey: "favorites.v1.abc")

        XCTAssertEqual(cloud.values["favorites.v1.abc"] as? [Int], [1001])
        XCTAssertEqual(cloud.synchronizeCount, 1, "seeding must not force a synchronize either")
    }

    func testRemoteChangeFoldsInAndNotifiesOnce() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        let folds = NSMutableArray()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values["favorites.v1.abc"] = [2002]
        cloud.postExternalChange(keys: ["favorites.v1.abc"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.array(forKey: "favorites.v1.abc") as? [Int], [2002], "remote wins")
        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual(folds.firstObject as? [String], ["favorites.v1.abc"])
    }

    func testTwoDeviceConflictRemoteWinsWholesale() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set([1], forKey: "favorites.v1.abc")

        cloud.values["favorites.v1.abc"] = [2, 3]
        cloud.postExternalChange(keys: ["favorites.v1.abc"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.array(forKey: "favorites.v1.abc") as? [Int], [2, 3])
    }

    func testRemoteDeletionPropagates() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(5, forKey: "some.key")

        cloud.values.removeValue(forKey: "some.key")
        cloud.postExternalChange(keys: ["some.key"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertNil(storage.object(forKey: "some.key"))
    }

    func testQuotaViolationAdoptsNothingAndStaysQuiet() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "kept.key")
        let folds = NSMutableArray()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values["kept.key"] = 999
        cloud.postExternalChange(keys: ["kept.key"], reason: NSUbiquitousKeyValueStoreQuotaViolationChange)

        XCTAssertEqual(storage.object(forKey: "kept.key") as? Int, 1, "local values stay authoritative on quota refusal")
        XCTAssertEqual(folds.count, 0)
    }

    func testAccountChangeAdoptsTheNewAccountsState() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "acct.key")

        cloud.values["acct.key"] = 2
        cloud.postExternalChange(keys: ["acct.key"], reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertEqual(storage.object(forKey: "acct.key") as? Int, 2)
    }

    /// The system may omit the per-key list for account changes and initial
    /// sync — the whole remote state must be adopted then, not skipped.
    func testAccountChangeWithoutAKeyListAdoptsTheWholeRemoteState() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "acct.key")
        let folds = NSMutableArray()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values = ["acct.key": 2, "other.key": 3]
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertEqual(storage.object(forKey: "acct.key") as? Int, 2)
        XCTAssertEqual(storage.object(forKey: "other.key") as? Int, 3)
        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual((folds.firstObject as? [String])?.sorted(), ["acct.key", "other.key"])
    }

    func testServerChangeWithoutAKeyListStaysANoOp() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "kept.key")

        cloud.values["kept.key"] = 99
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.object(forKey: "kept.key") as? Int, 1)
    }
}
