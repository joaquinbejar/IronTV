import XCTest
@testable import IronTV

/// Persisted playback settings arrive from UserDefaults/iCloud KVS — other
/// devices, other app versions, hand-edited plists — and feed timers, CMTime
/// and retry math directly. `load()` must therefore never surface a value
/// outside the documented constraints.
final class PlaybackSettingsValidationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "PlaybackSettingsValidationTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func load() -> PlaybackSettings {
        PlaybackSettingsStore(storage: defaults).load()
    }

    private func assertWithinConstraints(_ settings: PlaybackSettings, _ context: String) {
        XCTAssertTrue(PlaybackSettings.forwardBufferRange.contains(settings.forwardBufferSeconds), context)
        XCTAssertTrue(PlaybackSettings.liveEdgeOffsetRange.contains(settings.liveEdgeOffsetSeconds), context)
        XCTAssertTrue(PlaybackSettings.waitingTimeoutRange.contains(settings.waitingTimeoutSeconds), context)
        XCTAssertTrue(PlaybackSettings.frozenTimeoutRange.contains(settings.frozenTimeoutSeconds), context)
        XCTAssertTrue(PlaybackSettings.watchdogIntervalRange.contains(settings.watchdogIntervalSeconds), context)
        XCTAssertTrue(PlaybackSettings.maxReconnectAttemptsRange.contains(settings.maxReconnectAttempts), context)
        XCTAssertTrue(PlaybackSettings.apiTimeoutRange.contains(settings.apiTimeoutSeconds), context)
    }

    func testHostileNumericValuesNeverEscapeTheConstraints() {
        let hostileDoubles: [Double] = [.nan, .infinity, -.infinity, -5, 0, 1e12, -0.0, .leastNonzeroMagnitude]
        for value in hostileDoubles {
            defaults.set(value, forKey: "playback.watchdogIntervalSeconds")
            defaults.set(value, forKey: "playback.forwardBufferSeconds")
            defaults.set(value, forKey: "playback.liveEdgeOffsetSeconds")
            defaults.set(value, forKey: "playback.waitingTimeoutSeconds")
            defaults.set(value, forKey: "playback.frozenTimeoutSeconds")
            defaults.set(value, forKey: "playback.apiTimeoutSeconds")

            assertWithinConstraints(load(), "hostile value \(value)")
        }
    }

    func testNonFiniteValuesFallBackToTheDocumentedDefaults() {
        defaults.set(Double.nan, forKey: "playback.watchdogIntervalSeconds")
        defaults.set(Double.infinity, forKey: "playback.forwardBufferSeconds")

        let settings = load()

        XCTAssertEqual(settings.watchdogIntervalSeconds, PlaybackSettings.default.watchdogIntervalSeconds)
        XCTAssertEqual(settings.forwardBufferSeconds, PlaybackSettings.default.forwardBufferSeconds)
    }

    func testOutOfRangeValuesClampInsteadOfResetting() {
        defaults.set(0.0, forKey: "playback.watchdogIntervalSeconds")   // hot-timer input
        defaults.set(9999.0, forKey: "playback.forwardBufferSeconds")
        defaults.set(-3, forKey: "playback.maxReconnectAttempts")

        let settings = load()

        XCTAssertEqual(settings.watchdogIntervalSeconds, PlaybackSettings.watchdogIntervalRange.lowerBound)
        XCTAssertEqual(settings.forwardBufferSeconds, PlaybackSettings.forwardBufferRange.upperBound)
        XCTAssertEqual(settings.maxReconnectAttempts, PlaybackSettings.maxReconnectAttemptsRange.lowerBound)
    }

    func testUnknownEngineAndPartialDataFallBackToDefaults() {
        defaults.set("quicktime-9000", forKey: "playback.preferredEngine")
        defaults.set(12.0, forKey: "playback.liveEdgeOffsetSeconds") // only one field present

        let settings = load()

        XCTAssertEqual(settings.preferredEngine, PlaybackSettings.default.preferredEngine)
        XCTAssertEqual(settings.liveEdgeOffsetSeconds, 12)
        XCTAssertEqual(settings.waitingTimeoutSeconds, PlaybackSettings.default.waitingTimeoutSeconds)
    }

    func testLegacyIntegerTypedValuesStillLoad() {
        // An older version (or another platform) may have stored an Int.
        defaults.set(15, forKey: "playback.maxReconnectAttempts")

        XCTAssertEqual(load().maxReconnectAttempts, PlaybackSettings.maxReconnectAttemptsRange.upperBound)
    }

    func testTheDefaultsThemselvesAreWithinTheConstraints() {
        assertWithinConstraints(PlaybackSettings.default.validated(), "defaults")
        XCTAssertEqual(PlaybackSettings.default.validated(), PlaybackSettings.default, "defaults must survive validation unchanged")
    }
}
