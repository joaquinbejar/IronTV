import XCTest
@testable import IronTV

final class PlaybackSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "PlaybackSettingsStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLoadWithoutSavedValuesReturnsDefaults() {
        let store = PlaybackSettingsStore(storage: defaults)
        XCTAssertEqual(store.load(), .default)
    }

    func testRoundTrip() {
        let store = PlaybackSettingsStore(storage: defaults)
        let custom = PlaybackSettings(
            forwardBufferSeconds: 60,
            liveEdgeOffsetSeconds: 40,
            waitingTimeoutSeconds: 25,
            frozenTimeoutSeconds: 20,
            maxReconnectAttempts: 8,
            watchdogIntervalSeconds: 5,
            fastStart: false,
            apiTimeoutSeconds: 45,
            preferredEngine: .vlc
        )
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    func testResetRestoresDefaults() {
        let store = PlaybackSettingsStore(storage: defaults)
        var custom = PlaybackSettings.default
        custom.forwardBufferSeconds = 90
        store.save(custom)

        store.reset()
        XCTAssertEqual(store.load(), .default)
    }
}
