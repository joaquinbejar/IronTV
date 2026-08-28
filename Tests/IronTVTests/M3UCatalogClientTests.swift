import XCTest
@testable import IronTV

/// The playlist-backed catalog. Everything here is the pure build step —
/// entries in, `Category`/`LiveStream` out — so no network is involved.
final class M3UCatalogClientTests: XCTestCase {

    private func entry(_ name: String, _ url: String, group: String? = nil, tvgID: String? = nil) -> M3UEntry {
        M3UEntry(name: name, url: URL(string: url)!, logoURL: nil, tvgID: tvgID, group: group)
    }

    // MARK: - Catalog shape

    func testGroupsBecomeCategoriesInFirstSeenOrder() {
        let built = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "Sports"),
            entry("C", "http://h/3.m3u8", group: "News"),
        ])
        XCTAssertEqual(built.categories.map(\.name), ["News", "Sports"])
        XCTAssertEqual(built.streams.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(built.streams[0].categoryID, built.streams[2].categoryID)
    }

    func testUngroupedEntriesLandInTheirOwnCategory() {
        let built = M3UCatalogClient.build(from: [entry("Lonely", "http://h/1.m3u8")])
        XCTAssertEqual(built.categories.count, 1)
        XCTAssertEqual(built.streams.first?.categoryID, built.categories.first?.id)
    }

    /// `tvg-id` is exactly what the Xtream path puts in `epgChannelID`, so a
    /// playlist account loses nothing here.
    func testTVGIdentifierBecomesTheEPGChannelIdentifier() {
        let built = M3UCatalogClient.build(from: [entry("A", "http://h/1.m3u8", tvgID: "bbc.one")])
        XCTAssertEqual(built.streams.first?.epgChannelID, "bbc.one")
    }

    /// The planner applies its same-host trust policy to `directSourceURL`;
    /// putting the entry URL there is what makes playback work without the
    /// client synthesising Xtream-shaped URLs.
    func testEntryURLIsCarriedAsTheDirectSource() {
        let built = M3UCatalogClient.build(from: [entry("A", "http://h/1.m3u8")])
        XCTAssertEqual(built.streams.first?.directSourceURL?.absoluteString, "http://h/1.m3u8")
        XCTAssertEqual(built.urlsByStream[built.streams[0].id]?.absoluteString, "http://h/1.m3u8")
    }

    // MARK: - Identifier stability

    /// Favorites and the last-watched channel are stored by id, so an id that
    /// moved when the provider inserted a channel would silently repoint them.
    func testIdentifiersDependOnTheEntryNotItsPosition() {
        let first = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "News"),
        ])
        let afterInsertion = M3UCatalogClient.build(from: [
            entry("New", "http://h/0.m3u8", group: "News"),
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "News"),
        ])
        XCTAssertEqual(first.streams[0].id, afterInsertion.streams[1].id)
        XCTAssertEqual(first.streams[1].id, afterInsertion.streams[2].id)
        XCTAssertEqual(first.categories[0].id, afterInsertion.categories[0].id)
    }

    /// Swift's `hashValue` is seeded per process; these ids are persisted, so
    /// they must not be.
    func testIdentifiersAreStableAcrossCalls() {
        XCTAssertEqual(
            M3UCatalogClient.stableID(for: "http://h/1.m3u8"),
            M3UCatalogClient.stableID(for: "http://h/1.m3u8")
        )
        XCTAssertNotEqual(
            M3UCatalogClient.stableID(for: "http://h/1.m3u8"),
            M3UCatalogClient.stableID(for: "http://h/2.m3u8")
        )
    }

    func testIdentifiersAreNonNegative() {
        for text in ["", "http://h/1.m3u8", "ñ é 中文", String(repeating: "x", count: 4096)] {
            XCTAssertGreaterThanOrEqual(M3UCatalogClient.stableID(for: text), 0, "input: \(text.prefix(20))")
        }
    }

    /// Two entries are two channels even if their ids would have collided.
    func testDuplicateEntryURLsBothSurvive() {
        let built = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("A again", "http://h/1.m3u8", group: "News"),
        ])
        XCTAssertEqual(built.streams.count, 2)
        XCTAssertNotEqual(built.streams[0].id, built.streams[1].id)
    }
}

/// The cache policy the Settings expiry advertises. These drive the client
/// through a stubbed session so no network is involved.
final class M3UCatalogClientCacheTests: XCTestCase {

    /// Serves a fixed playlist body and counts how often it was asked for.
    private final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = """
        #EXTM3U
        #EXTINF:-1 group-title="News",A
        http://host.example.com/stream/1.m3u8
        """
        nonisolated(unsafe) static var requestCount = 0
        private static let lock = NSLock()

        static func reset() { lock.withLock { requestCount = 0 } }
        static var count: Int { lock.withLock { requestCount } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self.requestCount += 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(
        cacheLifetime: TimeInterval,
        now: @escaping @Sendable () -> Date,
        diskCache: PlaylistCacheStore? = nil
    ) -> M3UCatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return M3UCatalogClient(
            playlistURL: URL(string: "http://host.example.com/playlist.m3u")!,
            panelHost: URL(string: "http://host.example.com")!,
            cacheLifetime: cacheLifetime,
            session: URLSession(configuration: configuration),
            now: now,
            diskCache: diskCache,
            cacheNamespace: diskCache == nil ? nil : "v1.testnamespace"
        )
    }

    /// The finding this exists for: without a disk copy the expiry applied
    /// only within one client instance, so the default 24 hours still
    /// downloaded the whole playlist on every launch.
    func testASecondClientReusesThePlaylistFromDisk() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("M3UDiskCacheTests.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlaylistCacheStore(directory: directory)

        let first = makeClient(cacheLifetime: 3600, now: { Date() }, diskCache: disk)
        _ = try await first.liveCategories()
        XCTAssertEqual(CountingProtocol.count, 1)

        // A fresh client is what a relaunch looks like from here.
        let second = makeClient(cacheLifetime: 3600, now: { Date() }, diskCache: disk)
        _ = try await second.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 1, "the relaunch must be served from disk")
    }

    /// An explicit refresh has to clear the disk copy too, or the next launch
    /// is answered from the very file the user asked to replace.
    func testAnExplicitRefreshAlsoClearsTheDiskCopy() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("M3UDiskCacheTests.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlaylistCacheStore(directory: directory)

        let first = makeClient(cacheLifetime: 3600, now: { Date() }, diskCache: disk)
        _ = try await first.liveCategories()
        await first.invalidateCachedCatalog()

        let second = makeClient(cacheLifetime: 3600, now: { Date() }, diskCache: disk)
        _ = try await second.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 2)
    }

    override func setUp() {
        super.setUp()
        CountingProtocol.reset()
    }

    func testAFreshCacheIsReusedInsteadOfDownloadingAgain() async throws {
        let client = makeClient(cacheLifetime: 3600, now: { Date(timeIntervalSince1970: 0) })

        _ = try await client.liveCategories()
        _ = try await client.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 1, "the second read must come from the cache")
    }

    func testAStaleCacheIsRefetched() async throws {
        let clock = Clock()
        let client = makeClient(cacheLifetime: 60, now: { clock.now })

        _ = try await client.liveCategories()
        clock.advance(by: 61)
        _ = try await client.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 2)
    }

    /// The user's explicit refresh must reach past the expiry — otherwise it
    /// shows the very list they asked to replace.
    func testAnExplicitRefreshAlwaysRefetches() async throws {
        let client = makeClient(cacheLifetime: 3600, now: { Date(timeIntervalSince1970: 0) })

        _ = try await client.liveCategories()
        await client.invalidateCachedCatalog()
        _ = try await client.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 2)
    }

    /// A lifetime of zero is the documented "download every time" choice.
    func testZeroLifetimeDownloadsEveryTime() async throws {
        let client = makeClient(cacheLifetime: 0, now: { Date(timeIntervalSince1970: 0) })

        _ = try await client.liveCategories()
        _ = try await client.liveCategories()

        XCTAssertEqual(CountingProtocol.count, 2)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { date } }
        func advance(by seconds: TimeInterval) { lock.withLock { date += seconds } }
    }
}

/// The on-disk half of the cache: what makes the Settings expiry mean anything
/// across relaunches rather than only within one client instance.
final class PlaylistCacheStoreTests: XCTestCase {

    private var directory: URL!
    private var store: PlaylistCacheStore!
    private let namespace = "v1.abcdef0123456789"
    private let body = "#EXTM3U\n#EXTINF:-1,A\nhttp://host.example.com/stream/1.m3u8\n"
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PlaylistCacheStoreTests.\(UUID())", isDirectory: true)
        store = PlaylistCacheStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAMissReturnsNilRatherThanFailing() {
        XCTAssertNil(store.load(namespace: namespace, lifetime: 3600, now: epoch))
    }

    func testASavedPlaylistComesBackWithinItsLifetime() throws {
        store.save(body, namespace: namespace)
        let hit = try XCTUnwrap(store.load(namespace: namespace, lifetime: 3600, now: Date()))
        XCTAssertEqual(hit.body, body)
    }

    /// The timestamp is the download's, not the read's — otherwise every
    /// relaunch would restart the expiry the user configured.
    func testTheTimestampIsWhenItWasWrittenNotWhenItWasRead() throws {
        let before = Date()
        store.save(body, namespace: namespace)
        let hit = try XCTUnwrap(store.load(namespace: namespace, lifetime: 3600, now: Date()))
        XCTAssertGreaterThanOrEqual(hit.writtenAt.timeIntervalSince1970, before.timeIntervalSince1970 - 2)
        XCTAssertLessThanOrEqual(hit.writtenAt.timeIntervalSince1970, Date().timeIntervalSince1970 + 2)
    }

    func testAnExpiredCopyIsAMiss() {
        store.save(body, namespace: namespace)
        let farFuture = Date().addingTimeInterval(7200)
        XCTAssertNil(store.load(namespace: namespace, lifetime: 3600, now: farFuture))
    }

    /// Two accounts must not read each other's playlist.
    func testNamespacesAreIsolated() {
        store.save(body, namespace: namespace)
        XCTAssertNil(store.load(namespace: "v1.9999999999999999", lifetime: 3600, now: Date()))
    }

    func testRemoveIsAMissAfterwards() {
        store.save(body, namespace: namespace)
        store.remove(namespace: namespace)
        XCTAssertNil(store.load(namespace: namespace, lifetime: 3600, now: Date()))
    }

    /// A cache that cannot be read must never be able to break the app.
    func testCorruptDataDoesNotThrow() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(namespace).m3u")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        XCTAssertNil(store.load(namespace: namespace, lifetime: 3600, now: Date()))
    }

    /// The file name is a digest, so nothing on disk names the account.
    func testTheFileNameCarriesNoAccountMetadata() throws {
        store.save(body, namespace: namespace)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["\(namespace).m3u"])
        XCTAssertFalse(names.contains { $0.contains("host") || $0.contains("http") })
    }
}
