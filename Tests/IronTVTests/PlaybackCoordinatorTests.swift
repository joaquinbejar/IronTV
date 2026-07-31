import XCTest
@testable import IronTV

/// The coordinator is the one path from a selected channel to a running
/// engine. It is observed through its closure seams, so no AVPlayer is ever
/// created; the plan logic itself is covered by `ChannelsViewModelTests`.
final class PlaybackCoordinatorTests: XCTestCase {

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    private var defaults: UserDefaults!
    private let suiteName = "PlaybackCoordinatorTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Doubles

    /// Minimal deterministic catalog. The held account status is what lets a
    /// test change the selection while a plan is still being resolved — the
    /// plan awaits the capabilities fetch.
    private actor StubBrowser: ChannelBrowsing {
        private var status = AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1, allowedOutputFormats: nil
        )
        private var statusHeld = false
        private var statusWaiters: [CheckedContinuation<Void, Never>] = []

        func setStatus(_ newStatus: AccountStatus) { status = newStatus }
        func holdStatus() { statusHeld = true }

        func releaseStatus() {
            statusHeld = false
            statusWaiters.forEach { $0.resume() }
            statusWaiters.removeAll()
        }

        func accountStatus() async throws -> AccountStatus {
            if statusHeld {
                await withCheckedContinuation { statusWaiters.append($0) }
            }
            return status
        }

        func liveCategories() async throws -> [IronTV.Category] {
            [IronTV.Category(id: CategoryID(1), name: "A")]
        }

        func liveStreams(in categoryID: CategoryID?) async throws -> [LiveStream] {
            [PlaybackCoordinatorTests.stream]
        }

        nonisolated func playbackURL(for streamID: StreamID, format: XtreamClient.StreamFormat) throws -> URL {
            guard let url = URL(string: "http://host.example.com/live/u/p/\(streamID.rawValue).\(format.rawValue)") else {
                throw XtreamAPIError.invalidURL
            }
            return url
        }
    }

    private static let stream = LiveStream(
        id: StreamID(11), name: "S11", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil
    )

    /// Captures what reached the "player" side of the coordinator.
    @MainActor
    private final class EngineSpy {
        var played: [(stream: LiveStream, plan: ChannelsViewModel.PlaybackPlan)] = []
        var failures: [Error] = []
    }

    @MainActor
    private func makeViewModel(_ browser: StubBrowser) async -> ChannelsViewModel {
        let viewModel = ChannelsViewModel(
            account: account,
            lastChannel: LastChannelStore(identity: account.identity, storage: defaults),
            client: browser,
            preferenceStorage: defaults
        )
        for _ in 0..<20 { await Task.yield() }
        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()
        return viewModel
    }

    @MainActor
    private func makeCoordinator(_ viewModel: ChannelsViewModel, spy: EngineSpy) -> PlaybackCoordinator {
        PlaybackCoordinator(
            channels: viewModel,
            onPlay: { spy.played.append((stream: $0, plan: $1)) },
            onFailure: { spy.failures.append($0) }
        )
    }

    // MARK: - Tests

    @MainActor
    func testCurrentSelectionStartsPlaybackWithTheResolvedPlan() async throws {
        let browser = StubBrowser()
        let viewModel = await makeViewModel(browser)
        viewModel.selectedStreamID = Self.stream.id
        let spy = EngineSpy()

        await makeCoordinator(viewModel, spy: spy).startPlayback(of: Self.stream)

        XCTAssertEqual(spy.played.count, 1)
        XCTAssertEqual(spy.played.first?.stream, Self.stream)
        XCTAssertEqual(spy.played.first?.plan.primaryURL.pathExtension, "m3u8")
        XCTAssertEqual(spy.played.first?.plan.hlsAvailable, true)
        XCTAssertTrue(spy.failures.isEmpty)
    }

    @MainActor
    func testSelectionChangedWhilePlanningNeverReachesThePlayer() async {
        let browser = StubBrowser()
        await browser.holdStatus() // the plan will wait on capabilities
        let viewModel = await makeViewModel(browser)
        viewModel.selectedStreamID = Self.stream.id
        let spy = EngineSpy()
        let coordinator = makeCoordinator(viewModel, spy: spy)

        let start = Task { await coordinator.startPlayback(of: Self.stream) }
        await Task.yield()
        viewModel.selectedStreamID = StreamID(99) // the user moved on
        await browser.releaseStatus()
        await start.value

        XCTAssertTrue(spy.played.isEmpty, "a stale plan must not start playback for an abandoned channel")
        XCTAssertTrue(spy.failures.isEmpty)
    }

    @MainActor
    func testPlanFailureSurfacesThroughTheFailureSeam() async {
        let browser = StubBrowser()
        await browser.setStatus(AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1,
            allowedOutputFormats: [] // the panel advertises nothing playable
        ))
        let viewModel = await makeViewModel(browser)
        viewModel.selectedStreamID = Self.stream.id
        let spy = EngineSpy()

        await makeCoordinator(viewModel, spy: spy).startPlayback(of: Self.stream)

        XCTAssertTrue(spy.played.isEmpty)
        XCTAssertEqual(spy.failures.count, 1)
        guard case PlaybackError.noPlayableSource = spy.failures[0] else {
            return XCTFail("expected noPlayableSource, got \(spy.failures)")
        }
    }

    @MainActor
    func testStaleFailureIsDroppedWithTheSameCurrencyRule() async {
        let browser = StubBrowser()
        await browser.setStatus(AccountStatus(
            authenticated: true, status: "Active", expiryDate: nil, maxConnections: 1,
            allowedOutputFormats: []
        ))
        await browser.holdStatus()
        let viewModel = await makeViewModel(browser)
        viewModel.selectedStreamID = Self.stream.id
        let spy = EngineSpy()
        let coordinator = makeCoordinator(viewModel, spy: spy)

        let start = Task { await coordinator.startPlayback(of: Self.stream) }
        await Task.yield()
        viewModel.selectedStreamID = nil // background re-arm cleared it
        await browser.releaseStatus()
        await start.value

        XCTAssertTrue(spy.failures.isEmpty, "a stale failure must not overwrite state for a cleared selection")
        XCTAssertTrue(spy.played.isEmpty)
    }
}
