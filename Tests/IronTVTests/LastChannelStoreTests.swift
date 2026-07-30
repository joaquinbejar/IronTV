import XCTest
@testable import IronTV

final class LastChannelStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "LastChannelStoreTests"

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(for account: Account) -> LastChannelStore {
        LastChannelStore(identity: account.identity, storage: defaults)
    }

    func testRoundTripAndClear() {
        let store = makeStore(for: account)
        XCTAssertNil(store.lastCategory)
        XCTAssertNil(store.lastStreamID)

        store.lastCategory = .category(CategoryID(473))
        store.lastStreamID = StreamID(462274)
        XCTAssertEqual(store.lastCategory, .category(CategoryID(473)))
        XCTAssertEqual(store.lastStreamID, StreamID(462274))

        store.clear()
        XCTAssertNil(store.lastCategory)
        XCTAssertNil(store.lastStreamID)
    }

    func testAllChannelsSelectionRoundTrips() {
        let store = makeStore(for: account)
        store.lastCategory = .all
        XCTAssertEqual(store.lastCategory, .all)
    }

    func testFavoritesSelectionRoundTrips() {
        let store = makeStore(for: account)
        store.lastCategory = .favorites
        XCTAssertEqual(store.lastCategory, .favorites)
    }

    // MARK: - Account scoping

    /// The bug this scoping exists for: two panels reusing the same numeric IDs
    /// must not restore each other's selection.
    func testSelectionIsScopedPerProviderEvenWhenIDsCollide() {
        let other = Account(
            host: URL(string: "http://other.example.com:8080")!,
            username: "user1",
            password: "pass1"
        )
        let store = makeStore(for: account)
        let otherStore = makeStore(for: other)

        store.lastCategory = .category(CategoryID(473))
        store.lastStreamID = StreamID(462274)

        XCTAssertNil(otherStore.lastCategory)
        XCTAssertNil(otherStore.lastStreamID)

        otherStore.lastCategory = .category(CategoryID(473))
        otherStore.lastStreamID = StreamID(462274)
        XCTAssertEqual(store.lastCategory, .category(CategoryID(473)))
        XCTAssertEqual(store.lastStreamID, StreamID(462274))
    }

    func testTwoUsersOnTheSameHostDoNotShareSelection() {
        let sameHostOtherUser = Account(host: account.host, username: "user2", password: "pass2")
        let store = makeStore(for: account)
        let otherStore = makeStore(for: sameHostOtherUser)

        store.lastStreamID = StreamID(7)
        XCTAssertNil(otherStore.lastStreamID)
    }

    /// A password rotation is still the same account, so the user keeps their place.
    func testPasswordRotationKeepsSelection() {
        let store = makeStore(for: account)
        store.lastCategory = .category(CategoryID(12))
        store.lastStreamID = StreamID(99)

        let rotated = Account(host: account.host, username: account.username, password: "pass2")
        let rotatedStore = makeStore(for: rotated)

        XCTAssertEqual(rotatedStore.lastCategory, .category(CategoryID(12)))
        XCTAssertEqual(rotatedStore.lastStreamID, StreamID(99))
    }

    // MARK: - Migration off the pre-scoping global keys

    private func seedLegacyValues(category: Int, stream: Int) {
        defaults.set(category, forKey: "lastCategoryID")
        defaults.set(stream, forKey: "lastStreamID")
    }

    func testLegacyGlobalValuesMigrateIntoTheFirstAccountThenDisappear() {
        seedLegacyValues(category: 473, stream: 462274)

        let store = makeStore(for: account)
        XCTAssertEqual(store.lastCategory, .category(CategoryID(473)))
        XCTAssertEqual(store.lastStreamID, StreamID(462274))

        // Consumed, so a second provider can't inherit them.
        XCTAssertNil(defaults.object(forKey: "lastCategoryID"))
        XCTAssertNil(defaults.object(forKey: "lastStreamID"))

        let other = Account(host: URL(string: "http://other.example.com:8080")!, username: "u", password: "p")
        let otherStore = makeStore(for: other)
        XCTAssertNil(otherStore.lastCategory)
        XCTAssertNil(otherStore.lastStreamID)
    }

    func testLegacyValuesNeverOverwriteAnExistingScopedSelection() {
        let store = makeStore(for: account)
        store.lastCategory = .category(CategoryID(1))
        store.lastStreamID = StreamID(2)

        seedLegacyValues(category: 999, stream: 888)
        let reopened = makeStore(for: account)

        XCTAssertEqual(reopened.lastCategory, .category(CategoryID(1)))
        XCTAssertEqual(reopened.lastStreamID, StreamID(2))
        XCTAssertNil(defaults.object(forKey: "lastCategoryID"))
    }

    func testDiscardingLegacyValuesLeavesNothingToInherit() {
        seedLegacyValues(category: 473, stream: 462274)

        LastChannelStore.discardLegacyValues(in: defaults)

        let store = makeStore(for: account)
        XCTAssertNil(store.lastCategory)
        XCTAssertNil(store.lastStreamID)
    }
}
