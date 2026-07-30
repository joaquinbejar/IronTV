import XCTest
@testable import IronTV

final class FavoritesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "FavoritesStoreTests"

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

    func testRoundTrip() {
        let store = FavoritesStore(account: account, storage: defaults)
        XCTAssertTrue(store.load().isEmpty)

        store.save([StreamID(1001), StreamID(1002)])
        XCTAssertEqual(store.load(), [StreamID(1001), StreamID(1002)])

        store.save([])
        XCTAssertTrue(store.load().isEmpty)
    }

    /// Favorites are already synced to iCloud under this exact key. Rebuilding it
    /// from `AccountIdentity` must not change the string, or shipped users lose
    /// their favorites on update.
    func testStorageKeyMatchesTheKeyShippedBeforeAccountIdentity() {
        let store = FavoritesStore(account: account, storage: defaults)

        XCTAssertEqual(store.storageKey, "favorites.http://host.example.com:8080.user1")
        XCTAssertFalse(store.storageKey.contains(account.password))
    }

    /// A password rotation is the same account — favorites must survive it.
    func testFavoritesSurviveAPasswordRotation() {
        let store = FavoritesStore(account: account, storage: defaults)
        store.save([StreamID(1001)])

        let rotated = Account(host: account.host, username: account.username, password: "rotated")
        let rotatedStore = FavoritesStore(account: rotated, storage: defaults)

        XCTAssertEqual(rotatedStore.load(), [StreamID(1001)])
    }

    func testFavoritesAreScopedPerAccount() {
        let other = Account(host: account.host, username: "user2", password: "pass2")
        let store = FavoritesStore(account: account, storage: defaults)
        let otherStore = FavoritesStore(account: other, storage: defaults)

        store.save([StreamID(7)])
        XCTAssertTrue(otherStore.load().isEmpty)
    }
}
