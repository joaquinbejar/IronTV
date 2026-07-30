import XCTest
@testable import IronTV

/// Individual tests are `@MainActor`; setUp/tearDown stay nonisolated XCTest
/// lifecycle overrides, so the class carries no actor isolation.
final class PlaybackSettingsModelTests: XCTestCase {

    /// Counts writes so the no-save-loop guarantee is observable.
    private final class CountingStorage: KeyValueStorage {
        private let backing: UserDefaults
        private(set) var setCount = 0

        init(backing: UserDefaults) {
            self.backing = backing
        }

        func object(forKey defaultName: String) -> Any? { backing.object(forKey: defaultName) }
        func array(forKey defaultName: String) -> [Any]? { backing.array(forKey: defaultName) }
        func set(_ value: Any?, forKey defaultName: String) {
            setCount += 1
            backing.set(value, forKey: defaultName)
        }
        func removeObject(forKey defaultName: String) { backing.removeObject(forKey: defaultName) }
    }

    private var defaults: UserDefaults!
    private var storage: CountingStorage!
    private let suiteName = "PlaybackSettingsModelTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        storage = CountingStorage(backing: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeModel() -> PlaybackSettingsModel {
        PlaybackSettingsModel(store: PlaybackSettingsStore(storage: storage))
    }

    /// Mimics SyncedStorage's fold-in: the value lands in local storage, then
    /// the re-read notification fires on the main queue.
    @MainActor
    private func simulateRemoteChange(key: String, value: Any) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(
            name: SyncedStorage.didChangeExternallyNotification,
            object: nil,
            userInfo: [SyncedStorage.changedKeysUserInfoKey: [key]]
        )
    }

    /// The finding this model exists for: device B changes one field while the
    /// screen is open, the user then edits another — B's change must survive
    /// the full-snapshot save.
    @MainActor
    func testRemoteChangeSurvivesASubsequentLocalEdit() {
        let model = makeModel()

        simulateRemoteChange(key: "playback.apiTimeoutSeconds", value: 42.0)
        XCTAssertEqual(model.settings.apiTimeoutSeconds, 42, "the open screen must adopt the remote change")

        model.settings.forwardBufferSeconds = 25
        model.persist()

        let stored = PlaybackSettingsStore(storage: storage).load()
        XCTAssertEqual(stored.apiTimeoutSeconds, 42, "the remote change must not be undone by the local edit")
        XCTAssertEqual(stored.forwardBufferSeconds, 25)
    }

    /// Adopting a remote change makes the on-screen snapshot equal the stored
    /// one, so the view's onChange round-trip persists nothing.
    @MainActor
    func testAdoptingARemoteChangeDoesNotBounceASaveBack() {
        let model = makeModel()

        simulateRemoteChange(key: "playback.fastStart", value: false)
        let writesAfterAdoption = storage.setCount
        model.persist() // what the view's onChange would trigger

        XCTAssertEqual(storage.setCount, writesAfterAdoption, "adoption must not write nine stale fields back")
    }

    @MainActor
    func testNonPlaybackKeysAreIgnored() {
        let model = makeModel()
        let before = model.settings

        simulateRemoteChange(key: "favorites.v1.abc", value: [1])

        XCTAssertEqual(model.settings, before)
    }

    @MainActor
    func testPersistWritesOnlyWhenSomethingActuallyChanged() {
        let model = makeModel()
        let before = storage.setCount

        model.persist()
        XCTAssertEqual(storage.setCount, before, "an unchanged snapshot writes nothing")

        model.settings.fastStart.toggle()
        model.persist()
        XCTAssertGreaterThan(storage.setCount, before)
    }
}
