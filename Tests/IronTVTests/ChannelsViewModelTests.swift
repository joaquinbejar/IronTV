import XCTest
@testable import IronTV

@MainActor
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

    // MARK: - Doubles

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    /// Scripted catalog: per-category results, optional gates to hold a
    /// request in flight, and counters for the dedup assertions.
    private final class FakeBrowser: ChannelBrowsing, @unchecked Sendable {
        var categories: [IronTV.Category] = [IronTV.Category(id: CategoryID(1), name: "A"), IronTV.Category(id: CategoryID(2), name: "B")]
        var streamsByCategory: [Int: [LiveStream]] = [:]
        var allStreams: [LiveStream] = []
        var streamsError: Error?
        var streamsGate: Gate?
        var allStreamsGate: Gate?

        private let lock = NSLock()
        private var _allStreamsCalls = 0
        private var _categoryCalls: [Int] = []
        var allStreamsCalls: Int { lock.lock(); defer { lock.unlock() }; return _allStreamsCalls }
        var categoryCalls: [Int] { lock.lock(); defer { lock.unlock() }; return _categoryCalls }

        func liveCategories() async throws -> [IronTV.Category] { categories }

        func liveStreams(in categoryID: CategoryID?) async throws -> [LiveStream] {
            if let categoryID {
                lock.lock(); _categoryCalls.append(categoryID.rawValue); lock.unlock()
                if let streamsGate { await streamsGate.wait() }
                if let streamsError { throw streamsError }
                return streamsByCategory[categoryID.rawValue] ?? []
            }
            lock.lock(); _allStreamsCalls += 1; lock.unlock()
            if let allStreamsGate { await allStreamsGate.wait() }
            if let streamsError { throw streamsError }
            return allStreams
        }

        func playbackURL(for streamID: StreamID, format: XtreamClient.StreamFormat) throws -> URL {
            guard let url = URL(string: "http://host.example.com/live/u/p/\(streamID.rawValue).\(format.rawValue)") else {
                throw XtreamAPIError.invalidURL
            }
            return url
        }
    }

    private func stream(_ id: Int, _ name: String = "S") -> LiveStream {
        LiveStream(id: StreamID(id), name: "\(name)\(id)", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil)
    }

    private func makeViewModel(_ browser: FakeBrowser) -> ChannelsViewModel {
        ChannelsViewModel(
            account: account,
            lastChannel: LastChannelStore(identity: account.identity, storage: defaults),
            client: browser,
            preferenceStorage: defaults
        )
    }

    /// Lets the init-time categories load settle so tests start deterministic.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    // MARK: - Cancellation

    func testRapidCategorySwitchingOnlyTheFinalSelectionLands() async {
        let browser = FakeBrowser()
        browser.streamsByCategory = [1: [stream(11)], 2: [stream(22)]]
        let gate = Gate()
        browser.streamsGate = gate
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        viewModel.selectedCategory = .category(CategoryID(2))
        viewModel.selectedCategory = .category(CategoryID(1))
        await gate.open()
        await viewModel.loadStreams() // drains through the retained task path

        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(11)], "only the final selection may populate the list")
        XCTAssertEqual(viewModel.streamsPhase, .loaded)
    }

    func testStaleSuccessCannotTouchPhaseOrCache() async {
        let browser = FakeBrowser()
        browser.streamsByCategory = [1: [stream(11)], 2: [stream(22)]]
        let gate = Gate()
        browser.streamsGate = gate
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1)) // held by the gate
        browser.streamsGate = nil
        viewModel.selectedCategory = .category(CategoryID(2)) // completes immediately
        await Task.yield()
        await viewModel.loadStreams()
        await gate.open() // release the stale category-1 response
        await settle()

        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(22)])
        XCTAssertEqual(viewModel.streamsPhase, .loaded)
    }

    func testStaleFailureCannotFlashAnError() async {
        let browser = FakeBrowser()
        browser.streamsByCategory = [2: [stream(22)]]
        browser.streamsError = XtreamAPIError.httpStatus(500)
        let gate = Gate()
        browser.streamsGate = gate
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1)) // will fail, but held
        browser.streamsGate = nil
        browser.streamsError = nil
        viewModel.selectedCategory = .category(CategoryID(2))
        await Task.yield()
        await viewModel.loadStreams()
        await gate.open()
        await settle()

        XCTAssertEqual(viewModel.streamsPhase, .loaded, "a stale failure must not surface")
    }

    func testCancellationIsNotAUserFacingFailure() async {
        let browser = FakeBrowser()
        browser.streamsError = CancellationError()
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()

        XCTAssertNotEqual(viewModel.streamsPhase, .failed("cancelled"), "cancellation never reaches the failed phase")
        if case .failed = viewModel.streamsPhase {
            XCTFail("cancellation surfaced as a failure: \(viewModel.streamsPhase)")
        }
    }

    // MARK: - Retry

    func testRetryAfterFailureRecovers() async {
        let browser = FakeBrowser()
        browser.streamsError = XtreamAPIError.httpStatus(500)
        let viewModel = makeViewModel(browser)
        await settle()

        viewModel.selectedCategory = .category(CategoryID(1))
        await viewModel.loadStreams()
        guard case .failed = viewModel.streamsPhase else {
            return XCTFail("expected a failure first, got \(viewModel.streamsPhase)")
        }

        browser.streamsError = nil
        browser.streamsByCategory = [1: [stream(11)]]
        await viewModel.loadStreams(bypassCache: true)

        XCTAssertEqual(viewModel.streamsPhase, .loaded)
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(11)])
    }

    // MARK: - All-streams dedup

    func testConcurrentAllAndFavoritesIssueASingleFullListRequest() async {
        let browser = FakeBrowser()
        browser.allStreams = [stream(1), stream(2)]
        let gate = Gate()
        browser.allStreamsGate = gate
        let viewModel = makeViewModel(browser)
        await settle()
        viewModel.toggleFavorite(StreamID(2))

        viewModel.selectedCategory = .all       // starts the shared fetch, held
        await Task.yield()
        viewModel.selectedCategory = .favorites // must reuse the same fetch
        await Task.yield()
        await gate.open()
        await viewModel.loadStreams()
        await settle()

        XCTAssertEqual(browser.allStreamsCalls, 1, "All and Favorites must share one full-list request")
        XCTAssertEqual(viewModel.streams.map(\.id), [StreamID(2)], "favorites filter over the shared list")
    }

    // MARK: - Deallocation

    func testDeallocationCancelsInFlightWorkAndReleasesTheViewModel() async {
        let browser = FakeBrowser()
        let gate = Gate()
        browser.streamsGate = gate
        var viewModel: ChannelsViewModel? = makeViewModel(browser)
        await settle()
        viewModel?.selectedCategory = .category(CategoryID(1)) // held in flight
        await Task.yield()

        weak var weakViewModel = viewModel
        viewModel = nil
        await settle()

        XCTAssertNil(weakViewModel, "an in-flight load must not keep the view model alive")
        await gate.open() // releasing the gate afterwards must be harmless
        await settle()
    }
}
