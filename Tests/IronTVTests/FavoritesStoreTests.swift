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

    func testFavoritesAreScopedPerAccount() {
        let other = Account(host: account.host, username: "user2", password: "pass2")
        let store = FavoritesStore(account: account, storage: defaults)
        let otherStore = FavoritesStore(account: other, storage: defaults)

        store.save([StreamID(7)])
        XCTAssertTrue(otherStore.load().isEmpty)
    }
}
