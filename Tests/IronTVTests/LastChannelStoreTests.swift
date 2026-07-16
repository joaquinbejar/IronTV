import XCTest
@testable import IronTV

final class LastChannelStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "LastChannelStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRoundTripAndClear() {
        let store = LastChannelStore(storage: defaults)
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
        let store = LastChannelStore(storage: defaults)
        store.lastCategory = .all
        XCTAssertEqual(store.lastCategory, .all)
    }

    func testFavoritesSelectionRoundTrips() {
        let store = LastChannelStore(storage: defaults)
        store.lastCategory = .favorites
        XCTAssertEqual(store.lastCategory, .favorites)
    }
}
