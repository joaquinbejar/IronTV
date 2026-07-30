import XCTest
@testable import IronTV
#if canImport(VLCKitSPM)
import VLCKitSPM
#endif

/// Deterministic coverage of the reconnect/backoff machinery: injected sleep
/// and clock, an engine-start override instead of real players, and identity
/// tokens for the VLC delegate path. Individual tests are `@MainActor`.
final class PlayerViewModelReconnectTests: XCTestCase {

    /// Records scheduled retry delays and holds them until released.
    private actor SleepRecorder {
        private(set) var delays: [TimeInterval] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func sleep(_ delay: TimeInterval) async {
            delays.append(delay)
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// Mutable wall clock the view model reads through its injected `now`.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)

        var current: Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    private let stream = LiveStream(
        id: StreamID(1), name: "S1", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil
    )
    private let hlsURL = URL(string: "http://host.example.com/live/u/p/1.m3u8")!
    private let tsURL = URL(string: "http://host.example.com/live/u/p/1.ts")!

    /// Two fast attempts, then 3s/6s/… backoff — small numbers keep the
    /// arithmetic readable.
    private var testSettings: PlaybackSettings {
        var settings = PlaybackSettings.default
        settings.maxReconnectAttempts = 2
        return settings
    }

    @MainActor
    private func makePrimed(
        recorder: SleepRecorder,
        clock: TestClock
    ) -> (PlayerViewModel, attempts: () -> [URL]) {
        let viewModel = PlayerViewModel(
            settingsStore: PlaybackSettingsStore(storage: UserDefaults(suiteName: "PlayerVMTests.\(UUID())")!),
            retrySleep: { await recorder.sleep($0) },
            now: { clock.current }
        )
        final class Started: @unchecked Sendable { var urls: [URL] = [] }
        let started = Started()
        viewModel.reconnectStartOverride = { _, url in started.urls.append(url) }
        viewModel.primeForReconnectTesting(stream: stream, url: hlsURL, tsURL: tsURL, settings: testSettings)
        return (viewModel, { started.urls })
    }

    // MARK: - Backoff determinism

    @MainActor
    func testOnlyExecutedAttemptsCountAndSuppressedCallsScheduleOneRetry() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        viewModel.reconnect() // attempt 1 — immediate
        viewModel.reconnect() // attempt 2 — immediate
        XCTAssertEqual(viewModel.reconnectAttempts, 2)
        XCTAssertEqual(attempts().count, 2)

        // Attempt 3 needs a 3s backoff; the clock hasn't moved, so these are
        // all suppressed — the counter must not inflate (the old bug), and
        // exactly one retry may be scheduled.
        viewModel.reconnect()
        viewModel.reconnect()
        viewModel.reconnect()
        XCTAssertEqual(viewModel.reconnectAttempts, 2, "suppressed calls must not inflate the counter")
        XCTAssertEqual(viewModel.state, .reconnecting)
        var delays: [TimeInterval] = []
        for _ in 0..<200 where delays.isEmpty {
            delays = await recorder.delays
            await Task.yield()
        }
        XCTAssertEqual(delays.count, 1, "exactly one pending retry")
        XCTAssertEqual(delays.first ?? -1, 3, accuracy: 0.001)
    }

    @MainActor
    func testScheduledRetryExecutesTheNextAttemptWhenItsWindowArrives() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        viewModel.reconnect()
        viewModel.reconnect()
        viewModel.reconnect() // suppressed → schedules
        await Task.yield()

        clock.advance(3) // the backoff window has genuinely passed
        await recorder.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.reconnectAttempts, 3, "the scheduled retry must execute the attempt")
        XCTAssertEqual(attempts().count, 3)
    }

    @MainActor
    func testStopCancelsThePendingRetryAndResetsRecoveryState() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        viewModel.reconnect()
        viewModel.reconnect()
        viewModel.reconnect() // schedules
        await Task.yield()

        viewModel.stop()
        clock.advance(60)
        await recorder.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.reconnectAttempts, 0, "stop must reset the recovery history")
        XCTAssertEqual(attempts().count, 2, "a cancelled retry must not fire an attempt")
        XCTAssertNil(viewModel.currentURL)
        XCTAssertEqual(viewModel.state, .idle)
    }

    @MainActor
    func testAStalePendingRetryFromAPreviousSessionNeverFires() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        viewModel.reconnect()
        viewModel.reconnect()
        viewModel.reconnect() // schedules for this generation
        await Task.yield()

        // A new session supersedes the old one (prime again after stop).
        viewModel.stop()
        viewModel.primeForReconnectTesting(stream: stream, url: hlsURL, tsURL: tsURL, settings: testSettings)
        clock.advance(60)
        await recorder.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(viewModel.reconnectAttempts, 0, "a stale retry must not drive the new session")
        XCTAssertEqual(attempts().count, 2)
    }

    /// The review's recovery-before-delay scenario: playback becomes healthy
    /// while a scheduled retry is still sleeping — the retry must die, not
    /// restart a healthy stream (its generation is still valid, so only an
    /// explicit cancel can stop it).
    @MainActor
    func testHealthyRecoveryBeforeTheDelayKillsThePendingRetry() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        viewModel.reconnect()
        viewModel.reconnect()
        viewModel.reconnect() // suppressed → schedules the backoff retry
        await Task.yield()

        viewModel.noteHealthyPlayback() // the stream recovered on its own

        clock.advance(60)
        await recorder.release()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(attempts().count, 2, "the pending retry must not restart a healthy stream")
        XCTAssertEqual(viewModel.reconnectAttempts, 0, "healthy progress resets the budget")
    }

    // MARK: - URL identity

    @MainActor
    func testHLSAndTSIdentitiesAreDistinctAndSurviveRecovery() async {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        XCTAssertEqual(viewModel.currentURL, hlsURL)
        XCTAssertEqual(viewModel.currentTSURL, tsURL)

        viewModel.reconnect() // AV attempt must use the HLS identity
        XCTAssertEqual(attempts().last, hlsURL, "an AVPlayer reconnect must never receive the TS URL")
        XCTAssertEqual(viewModel.currentURL, hlsURL)
        XCTAssertEqual(viewModel.currentTSURL, tsURL)
    }

    // MARK: - Stale VLC callbacks

    #if canImport(VLCKitSPM)
    @MainActor
    func testVLCEventsFromAnUnknownPlayerIdentityAreIgnored() {
        let recorder = SleepRecorder()
        let clock = TestClock()
        let (viewModel, attempts) = makePrimed(recorder: recorder, clock: clock)

        // No current VLC player at all: any identity is stale by definition.
        let staleID = ObjectIdentifier(NSObject())
        viewModel.vlcStateChanged(.error, fromPlayerID: staleID)
        viewModel.vlcStateChanged(.stopped, fromPlayerID: staleID)
        viewModel.vlcTimeAdvanced(fromPlayerID: staleID)

        XCTAssertEqual(viewModel.state, .idle, "stale VLC events must not touch state")
        XCTAssertEqual(viewModel.reconnectAttempts, 0)
        XCTAssertTrue(attempts().isEmpty)
    }
    #endif
}
