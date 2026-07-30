import XCTest
@testable import IronTV

final class AccountPreferenceMigratorTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AccountPreferenceMigratorTests"

    private let httpAccount = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )
    private let httpsAccount = Account(
        host: URL(string: "https://host.example.com:8080")!,
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

    func testCopiesFavoritesAndLastChannelToTheNewNamespace() {
        FavoritesStore(account: httpAccount, storage: defaults).save([StreamID(7), StreamID(9)])
        let oldChannel = LastChannelStore(identity: httpAccount.identity, storage: defaults)
        oldChannel.lastCategory = .category(CategoryID(3))
        oldChannel.lastStreamID = StreamID(9)

        AccountPreferenceMigrator.migrate(from: httpAccount, to: httpsAccount, storage: defaults)

        XCTAssertEqual(FavoritesStore(account: httpsAccount, storage: defaults).load(), [StreamID(7), StreamID(9)])
        let newChannel = LastChannelStore(identity: httpsAccount.identity, storage: defaults)
        XCTAssertEqual(newChannel.lastCategory, .category(CategoryID(3)))
        XCTAssertEqual(newChannel.lastStreamID, StreamID(9))
    }

    func testNeverClobbersValuesAlreadyStoredUnderTheNewNamespace() {
        FavoritesStore(account: httpAccount, storage: defaults).save([StreamID(7)])
        FavoritesStore(account: httpsAccount, storage: defaults).save([StreamID(42)])
        LastChannelStore(identity: httpAccount.identity, storage: defaults).lastStreamID = StreamID(7)
        LastChannelStore(identity: httpsAccount.identity, storage: defaults).lastStreamID = StreamID(42)

        AccountPreferenceMigrator.migrate(from: httpAccount, to: httpsAccount, storage: defaults)

        XCTAssertEqual(FavoritesStore(account: httpsAccount, storage: defaults).load(), [StreamID(42)])
        XCTAssertEqual(LastChannelStore(identity: httpsAccount.identity, storage: defaults).lastStreamID, StreamID(42))
    }

    func testNoOpWhenTheOldNamespaceHoldsNothing() {
        AccountPreferenceMigrator.migrate(from: httpAccount, to: httpsAccount, storage: defaults)

        XCTAssertTrue(FavoritesStore(account: httpsAccount, storage: defaults).load().isEmpty)
        let newChannel = LastChannelStore(identity: httpsAccount.identity, storage: defaults)
        XCTAssertNil(newChannel.lastCategory)
        XCTAssertNil(newChannel.lastStreamID)
    }
}
