import XCTest
@testable import IronTV

/// Sync behavior against a scripted cloud store: batching, first-sync
/// seeding, conflicts, deletions, and change reasons — no iCloud container.
/// Individual tests are `@MainActor` (fold-in notifications are delivered on
/// the main queue); setUp/tearDown stay nonisolated XCTest lifecycle
/// overrides, so the class itself carries no actor isolation.
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

    /// Synchronized recorder for fold-in notifications — safe to capture in
    /// the `@Sendable` observer closure, unlike an NSMutableArray.
    private final class FoldRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []

        func record(_ keys: [String]) {
            lock.lock()
            recorded.append(keys)
            lock.unlock()
        }

        var folds: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
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

    /// Records our re-read notifications while keeping the token owned.
    private func observeFolds(into recorder: FoldRecorder) -> TeardownBag {
        let bag = TeardownBag()
        bag.store(NotificationCenter.default.addObserver(
            forName: SyncedStorage.didChangeExternallyNotification,
            object: nil,
            queue: .main
        ) { notification in
            let keys = notification.userInfo?[SyncedStorage.changedKeysUserInfoKey] as? [String] ?? []
            recorder.record(keys)
        })
        return bag
    }

    @MainActor
    func testInitAdoptsExistingCloudStateWithASingleSynchronize() {
        let cloud = FakeCloudStore()
        cloud.values = ["remote.key": 7]

        let storage = SyncedStorage(defaults: defaults, cloud: cloud)

        XCTAssertEqual(storage.object(forKey: "remote.key") as? Int, 7)
        XCTAssertEqual(cloud.synchronizeCount, 1, "exactly the deliberate startup synchronize")
    }

    @MainActor
    func testBurstSettingsSaveForcesNoAdditionalSynchronize() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        var settings = PlaybackSettings.default
        settings.apiTimeoutSeconds = 42

        PlaybackSettingsStore(storage: storage).save(settings)

        XCTAssertEqual(cloud.synchronizeCount, 1, "nine field writes must not force nine syncs")
        XCTAssertEqual(cloud.values["playback.apiTimeoutSeconds"] as? Double, 42, "writes still mirror to the cloud")
    }

    @MainActor
    func testFirstSyncSeedsALocalValueOnRead() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        defaults.set([1001], forKey: "favorites.v1.abc")

        _ = storage.array(forKey: "favorites.v1.abc")

        XCTAssertEqual(cloud.values["favorites.v1.abc"] as? [Int], [1001])
        XCTAssertEqual(cloud.synchronizeCount, 1, "seeding must not force a synchronize either")
    }

    @MainActor
    func testRemoteChangeFoldsInAndNotifiesOnce() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        let folds = FoldRecorder()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values["favorites.v1.abc"] = [2002]
        cloud.postExternalChange(keys: ["favorites.v1.abc"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.array(forKey: "favorites.v1.abc") as? [Int], [2002], "remote wins")
        XCTAssertEqual(folds.folds, [["favorites.v1.abc"]])
    }

    @MainActor
    func testTwoDeviceConflictRemoteWinsWholesale() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set([1], forKey: "favorites.v1.abc")

        cloud.values["favorites.v1.abc"] = [2, 3]
        cloud.postExternalChange(keys: ["favorites.v1.abc"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.array(forKey: "favorites.v1.abc") as? [Int], [2, 3])
    }

    @MainActor
    func testRemoteDeletionPropagates() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(5, forKey: "some.key")

        cloud.values.removeValue(forKey: "some.key")
        cloud.postExternalChange(keys: ["some.key"], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertNil(storage.object(forKey: "some.key"))
    }

    @MainActor
    func testQuotaViolationAdoptsNothingAndStaysQuiet() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "kept.key")
        let folds = FoldRecorder()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values["kept.key"] = 999
        cloud.postExternalChange(keys: ["kept.key"], reason: NSUbiquitousKeyValueStoreQuotaViolationChange)

        XCTAssertEqual(storage.object(forKey: "kept.key") as? Int, 1, "local values stay authoritative on quota refusal")
        XCTAssertTrue(folds.folds.isEmpty)
    }

    @MainActor
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
    @MainActor
    func testAccountChangeWithoutAKeyListAdoptsTheWholeRemoteState() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "acct.key")
        let folds = FoldRecorder()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values = ["acct.key": 2, "other.key": 3]
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertEqual(storage.object(forKey: "acct.key") as? Int, 2)
        XCTAssertEqual(storage.object(forKey: "other.key") as? Int, 3)
        XCTAssertEqual(folds.folds.count, 1)
        XCTAssertEqual(folds.folds.first?.sorted(), ["acct.key", "other.key"])
    }

    /// An account change *replaces* the previous account's data: mirrored keys
    /// the new account doesn't have must be removed, not left behind.
    @MainActor
    func testAccountChangeRemovesValuesOnlyThePreviousAccountHad() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "old-account-only.key")
        storage.set(1, forKey: "shared.key")
        let folds = FoldRecorder()
        let bag = observeFolds(into: folds)
        defer { bag.removeObservers() }

        cloud.values = ["shared.key": 2]
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertNil(storage.object(forKey: "old-account-only.key"), "the previous account's value must not survive")
        XCTAssertEqual(storage.object(forKey: "shared.key") as? Int, 2)
        XCTAssertEqual(folds.folds.first?.sorted(), ["old-account-only.key", "shared.key"])
    }

    @MainActor
    func testAccountChangeToAnEmptyStoreClearsEveryMirroredKey() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "a.key")
        storage.set(2, forKey: "b.key")

        cloud.values = [:]
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreAccountChange)

        XCTAssertNil(storage.object(forKey: "a.key"))
        XCTAssertNil(storage.object(forKey: "b.key"))
    }

    @MainActor
    func testServerChangeWithoutAKeyListStaysANoOp() {
        let cloud = FakeCloudStore()
        let storage = SyncedStorage(defaults: defaults, cloud: cloud)
        storage.set(1, forKey: "kept.key")

        cloud.values["kept.key"] = 99
        cloud.postExternalChange(keys: [], reason: NSUbiquitousKeyValueStoreServerChange)

        XCTAssertEqual(storage.object(forKey: "kept.key") as? Int, 1)
    }
}
