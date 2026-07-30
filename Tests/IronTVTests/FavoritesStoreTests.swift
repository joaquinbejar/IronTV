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

    /// Favorites shipped (and synced to iCloud) under the plaintext
    /// `host.username` key. That value must keep loading — now via migration
    /// to the digest key, which also scrubs the account metadata from the
    /// key name.
    func testValuesUnderTheShippedPlaintextKeyMigrateToTheDigestKey() {
        let shippedKey = "favorites.http://host.example.com:8080.user1"
        defaults.set([1001], forKey: shippedKey)

        let store = FavoritesStore(account: account, storage: defaults)

        XCTAssertEqual(store.load(), [StreamID(1001)], "shipped favorites must survive the key migration")
        XCTAssertNil(defaults.object(forKey: shippedKey), "the plaintext key must be gone after migration")
        XCTAssertTrue(store.storageKey.hasPrefix("favorites.v1."))
        XCTAssertFalse(store.storageKey.contains("host.example.com"))
        XCTAssertFalse(store.storageKey.contains("user1"))
        XCTAssertFalse(store.storageKey.contains(account.password))
    }

    func testMigrationNeverClobbersAValueAlreadyUnderTheDigestKey() {
        let store = FavoritesStore(account: account, storage: defaults)
        store.save([StreamID(42)])
        defaults.set([1001], forKey: "favorites.http://host.example.com:8080.user1")

        let rebuilt = FavoritesStore(account: account, storage: defaults)

        XCTAssertEqual(rebuilt.load(), [StreamID(42)], "an existing digest-key value must win over a reappearing legacy key")
        XCTAssertNil(defaults.object(forKey: "favorites.http://host.example.com:8080.user1"))
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
