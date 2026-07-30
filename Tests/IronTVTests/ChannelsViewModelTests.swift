import XCTest
@testable import IronTV

/// Individual tests are `@MainActor`; setUp/tearDown stay nonisolated XCTest
/// lifecycle overrides, so the class carries no actor isolation.
final class ChannelsViewModelTests: XCTestCase {

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    private var defaults: UserDefaults!
    private let suiteName = "ChannelsViewModelTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Scripted browser

    /// Deterministic catalog double. An actor, so the whole script and every
    /// counter share one isolation domain; `waitUntilStreamRequests(_:)` is
    /// the handshake that lets a test know a fetch has actually entered
    /// before it flips state; held fetches react to cancellation by throwing,
    /// which is what makes "provider work stopped" observable.
    private actor ScriptedBrowser: ChannelBrowsing {
        struct Script {
            var categories: [IronTV.Category] = [
                IronTV.Category(id: CategoryID(1), name: "A"),
                IronTV.Category(id: CategoryID(2), name: "B"),
            ]
            var streamsByCategory: [Int: [LiveStream]] = [:]
            var allStreams: [LiveStream] = []
            /// Categories whose fetch stays suspended until `releaseHolds()`;
            /// use `-1` for the full-list fetch.
            var held: Set<Int> = []
            /// Categories whose fetch throws this error; `-1` for the full list.
            var errors: [Int: Error] = [:]
        }

        private var script = Script()
        private(set) var categoryCalls: [Int] = []
        private(set) var allStreamsCalls = 0
        private(set) var cancelledFetches = 0
        private var holdWaiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var streamRequests = 0

        func configure(_ mutate: @Sendable (inout Script) -> Void) {
            mutate(&script)
        }

        /// Suspends until at least `count` stream fetches have entered.
        func waitUntilStreamRequests(_ count: Int) async {
            if streamRequests >= count { return }
            await withCheckedContinuation { entryWaiters.append((count, $0)) }
        }

        func releaseHolds() {
            script.held = []
            holdWaiters.forEach { $0.resume() }
            holdWaiters.removeAll()
        }

        private func recordEntry() {
            streamRequests += 1
            let reached = streamRequests
            let ready = entryWaiters.filter { $0.threshold <= reached }
            entryWaiters.removeAll { $0.threshold <= reached }
            ready.forEach { $0.continuation.resume() }
        }

        private func holdIfScripted(_ slot: Int) async throws {
            if script.held.contains(slot) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if script.held.contains(slot) {
                            holdWaiters.append(continuation)
                        } else {
                            continuation.resume()
                        }
                    }
                } onCancel: {
                    Task { await self.releaseHolds() }
                }
            }
            do {
                try Task.checkCancellation()
            } catch {
                cancelledFetches += 1
                throw error
            }
        }

        private var accountStatusResult = AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1, allowedOutputFormats: nil
        )
        private var accountStatusHeld = false
        private var accountStatusWaiters: [CheckedContinuation<Void, Never>] = []

        func setAccountStatus(_ status: AccountStatus) {
            accountStatusResult = status
        }

        func holdAccountStatus() {
            accountStatusHeld = true
        }

        func releaseAccountStatus() {
            accountStatusHeld = false
            accountStatusWaiters.forEach { $0.resume() }
            accountStatusWaiters.removeAll()
        }

        func accountStatus() async throws -> AccountStatus {
            if accountStatusHeld {
                await withCheckedContinuation { accountStatusWaiters.append($0) }
            }
            return accountStatusResult
        }

        func liveCategories() async throws -> [IronTV.Category] {
            script.categories
        }

        func liveStreams(in categoryID: CategoryID?) async throws -> [LiveStream] {
            let slot = categoryID?.rawValue ?? -1
            if let categoryID {
                categoryCalls.append(categoryID.rawValue)
            } else {
                allStreamsCalls += 1
            }
            recordEntry()
            try await holdIfScripted(slot)
            if let error = script.errors[slot] { throw error }
            if categoryID == nil { return script.allStreams }
            return script.streamsByCategory[slot] ?? []
        }

        nonisolated func playbackURL(for streamID: StreamID, format: XtreamClient.StreamFormat) throws -> URL {
            guard let url = URL(string: "http://host.example.com/live/u/p/\(streamID.rawValue).\(format.rawValue)") else {
                throw XtreamAPIError.invalidURL
            }
            return url
        }
    }

    /// Portable weak holder: `weak let` needs a newer toolchain than CI's,
    /// and a local `weak var` that is never mutated warns — a class property
    /// does neither.
    private final class WeakRef<T: AnyObject> {
        private(set) weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    private static func stream(_ id: Int) -> LiveStream {
        LiveStream(id: StreamID(id), name: "S\(id)", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil)
    }

    @MainActor
    private func makeViewModel(_ browser: ScriptedBrowser) -> ChannelsViewModel {
        ChannelsViewModel(
            account: account,
            lastChannel: LastChannelStore(identity: account.identity, storage: defaults),
            client: browser,
            preferenceStorage: defaults
        )
    }

    /// Lets scheduled main-actor work drain so assertions are deterministic.
    @MainActor
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Cancellation

    /// The regression the review caught: waiters cancelled before they ever
    /// ran must not reach the provider — a rapid A→B→A switch performs
    /// exactly one fetch, for the final selection.
    @MainActor
    func testRapidSwitchingFetchesOnlyTheFinalSelection() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)], 2: [Self.stream(22)]] }
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        viewModel.selectedCategory = .category(CategoryID(2))
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()
        await settle()

        let calls = await browser.categoryCalls
        XCTAssertEqual(calls, [1], "already-cancelled waiters must never reach the provider")
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(11)])
        XCTAssertEqual(viewModel.streamsPhase, .loaded)
    }

    @MainActor
    func testStaleSuccessCannotTouchPhaseOrList() async {
        let browser = ScriptedBrowser()
        await browser.configure {
            $0.streamsByCategory = [1: [Self.stream(11)], 2: [Self.stream(22)]]
            $0.held = [1]
        }
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        await browser.waitUntilStreamRequests(1) // A's fetch is genuinely in flight
        viewModel.selectedCategory = .category(CategoryID(2))
        await viewModel.loadStreams()
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(22)])

        await browser.releaseHolds() // the stale A response arrives late
        await settle()

        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(22)], "a stale success must change nothing")
        XCTAssertEqual(viewModel.streamsPhase, .loaded)
    }

    @MainActor
    func testStaleFailureCannotFlashAnError() async {
        let browser = ScriptedBrowser()
        await browser.configure {
            $0.streamsByCategory = [2: [Self.stream(22)]]
            $0.errors = [1: XtreamAPIError.httpStatus(500)]
            $0.held = [1]
        }
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        await browser.waitUntilStreamRequests(1) // the failing fetch is held in flight
        viewModel.selectedCategory = .category(CategoryID(2))
        await viewModel.loadStreams()

        await browser.releaseHolds() // the stale failure arrives late
        await settle()

        XCTAssertEqual(viewModel.streamsPhase, .loaded, "a stale failure must not surface")
    }

    /// Both cancellation shapes: raw URLError(.cancelled) from a conformer,
    /// and the client's wrapped XtreamAPIError.network form.
    @MainActor
    func testCancellationIsNeverAUserFacingFailure() async {
        for cancellation: Error in [
            CancellationError(),
            URLError(.cancelled),
            XtreamAPIError.network(URLError(.cancelled)),
        ] {
            let browser = ScriptedBrowser()
            await browser.configure { [cancellation] in $0.errors = [1: cancellation] }
            let viewModel = makeViewModel(browser)
            await settle()

            viewModel.selectedCategory = .category(CategoryID(1))
            await viewModel.loadStreams()

            if case .failed = viewModel.streamsPhase {
                XCTFail("cancellation surfaced as a failure for \(cancellation)")
            }
        }
    }

    // MARK: - Retry

    @MainActor
    func testRetryAfterFailureRecovers() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.errors = [1: XtreamAPIError.httpStatus(500)] }
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()
        guard case .failed = viewModel.streamsPhase else {
            return XCTFail("expected a failure first, got \(viewModel.streamsPhase)")
        }

        await browser.configure {
            $0.errors = [:]
            $0.streamsByCategory = [1: [Self.stream(11)]]
        }
        await viewModel.loadStreams(bypassCache: true)

        XCTAssertEqual(viewModel.streamsPhase, .loaded)
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(11)])
    }

    // MARK: - All-streams dedup

    @MainActor
    func testConcurrentAllAndFavoritesIssueASingleFullListRequest() async {
        let browser = ScriptedBrowser()
        await browser.configure {
            $0.allStreams = [Self.stream(1), Self.stream(2)]
            $0.held = [-1]
        }
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.toggleFavorite(StreamID(2))

        viewModel.selectedCategory = .all
        await browser.waitUntilStreamRequests(1) // the shared fetch is in flight
        viewModel.selectedCategory = .favorites  // must reuse it, not re-fetch
        await browser.releaseHolds()
        await viewModel.loadStreams()
        await settle()

        let fullListCalls = await browser.allStreamsCalls
        XCTAssertEqual(fullListCalls, 1, "All and Favorites must share one full-list request")
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(2)], "favorites filter over the shared list")
    }

    // MARK: - Playback plans

    @MainActor
    func testTSOnlyPanelPlansLeadWithVLC() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)]] }
        await browser.setAccountStatus(AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1,
            allowedOutputFormats: [.ts]
        ))
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        let plan = try? await viewModel.playbackPlan(for: StreamID(11))
        XCTAssertEqual(plan?.hlsAvailable, false, "a TS-only panel must lead with the VLC engine")
        XCTAssertEqual(plan?.primaryURL.pathExtension, "ts")
    }

    @MainActor
    func testNothingPlayableSurfacesATypedError() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)]] }
        await browser.setAccountStatus(AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1,
            allowedOutputFormats: []
        ))
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        do {
            _ = try await viewModel.playbackPlan(for: StreamID(11))
            XCTFail("expected noPlayableSource")
        } catch {
            guard case PlaybackError.noPlayableSource = error else {
                return XCTFail("expected noPlayableSource, got \(error)")
            }
        }
    }

    @MainActor
    func testAbsentCapabilitiesKeepTodaysHLSPlusTSBehavior() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)]] }
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        let plan = try? await viewModel.playbackPlan(for: StreamID(11))
        XCTAssertEqual(plan?.hlsAvailable, true)
        XCTAssertEqual(plan?.primaryURL.pathExtension, "m3u8")
        XCTAssertEqual(plan?.tsURL?.pathExtension, "ts")
    }

    /// The review's race: a channel selected before the capabilities fetch
    /// answers must still plan against what the panel advertises.
    @MainActor
    func testPlanWaitsForPendingCapabilitiesInsteadOfAssumingBoth() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)]] }
        await browser.setAccountStatus(AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1,
            allowedOutputFormats: [.ts]
        ))
        await browser.holdAccountStatus() // capabilities stay pending
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        let planTask = Task { try await viewModel.playbackPlan(for: StreamID(11)) }
        await Task.yield()
        await browser.releaseAccountStatus() // the panel finally answers: TS-only

        let plan = try? await planTask.value
        XCTAssertEqual(plan?.hlsAvailable, false, "a plan requested before capabilities arrived must still honor them")
        XCTAssertEqual(plan?.primaryURL.pathExtension, "ts")
    }

    /// The background/foreground re-arm path: clearing the selection and
    /// tapping the same row again must be a real change that re-enters the
    /// playback path (and keeps the last-channel memory).
    @MainActor
    func testClearingAndReselectingTheSameStreamReFires() async {
        let browser = ScriptedBrowser()
        await browser.configure { $0.streamsByCategory = [1: [Self.stream(11)]] }
        let lastChannel = LastChannelStore(identity: account.identity, storage: defaults)
        let viewModel = ChannelsViewModel(
            account: account, lastChannel: lastChannel, client: browser, preferenceStorage: defaults
        )
        await settle()
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        viewModel.selectedStreamID = StreamID(11)
        XCTAssertEqual(lastChannel.lastStreamID, StreamID(11))

        viewModel.selectedStreamID = nil // background re-arm
        viewModel.selectedStreamID = StreamID(11) // one-tap replay

        XCTAssertEqual(viewModel.selectedStreamID, StreamID(11))
        XCTAssertEqual(lastChannel.lastStreamID, StreamID(11), "the last-channel memory survives the re-arm")
    }

    // MARK: - Deallocation

    @MainActor
    func testDeallocationCancelsTheInFlightProviderFetch() async {
        let browser = ScriptedBrowser()
        await browser.configure {
            $0.streamsByCategory = [1: [Self.stream(11)]]
            $0.held = [1]
        }
        var viewModel: ChannelsViewModel? = makeViewModel(browser)
        await settle()
        viewModel?.selectedCategory = .category(CategoryID(1))
        await browser.waitUntilStreamRequests(1) // provider work genuinely started

        let released = WeakRef(viewModel)
        viewModel = nil
        await settle()

        XCTAssertNil(released.value, "an in-flight load must not keep the view model alive")
        // The gate reacts to cancellation: the fetch must have stopped, not
        // merely been abandoned.
        for _ in 0..<50 {
            if await browser.cancelledFetches > 0 { break }
            await Task.yield()
        }
        let cancelled = await browser.cancelledFetches
        XCTAssertGreaterThan(cancelled, 0, "releasing the owner must cancel the provider fetch itself")
    }
}
