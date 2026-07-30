import XCTest
@testable import IronTV

/// Fully offline: the loader's fetch seam is scripted, so these tests observe
/// dedupe, caching, failure tolerance, and cancellation without a network.
final class ChannelIconLoaderTests: XCTestCase {

    /// 1×1 PNG — the smallest payload ImageIO decodes successfully.
    private static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private static let iconURL = URL(string: "http://icons.example.com/one.png")!

    /// Scripted fetch: records requests, can hold them open, reacts to
    /// cancellation by throwing — the same idiom as the catalog doubles.
    private actor FetchScript {
        private(set) var requests: [URL] = []
        private(set) var cancelledFetches = 0
        private var held = false
        private var holdWaiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var payload: Data = ChannelIconLoaderTests.pngData
        var statusCode = 200

        func setPayload(_ data: Data) { payload = data }
        func setStatusCode(_ code: Int) { statusCode = code }
        func hold() { held = true }

        func release() {
            held = false
            holdWaiters.forEach { $0.resume() }
            holdWaiters.removeAll()
        }

        /// Suspends until at least `count` fetches have entered.
        func waitUntilRequests(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { entryWaiters.append((count, $0)) }
        }

        func fetch(_ url: URL) async throws -> (Data, URLResponse) {
            requests.append(url)
            let reached = requests.count
            let ready = entryWaiters.filter { $0.threshold <= reached }
            entryWaiters.removeAll { $0.threshold <= reached }
            ready.forEach { $0.continuation.resume() }
            if held {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if held {
                            holdWaiters.append(continuation)
                        } else {
                            continuation.resume()
                        }
                    }
                } onCancel: {
                    Task { await self.release() }
                }
            }
            do {
                try Task.checkCancellation()
            } catch {
                cancelledFetches += 1
                throw error
            }
            guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (payload, response)
        }
    }

    @MainActor
    private func makeLoader(_ script: FetchScript) -> ChannelIconLoader {
        ChannelIconLoader(fetch: { try await script.fetch($0) })
    }

    @MainActor
    func testConcurrentRequestsForTheSameURLShareOneFetch() async {
        let script = FetchScript()
        await script.hold()
        let loader = makeLoader(script)

        let first = Task { await loader.image(for: Self.iconURL) }
        let second = Task { await loader.image(for: Self.iconURL) }
        await script.waitUntilRequests(1)
        await script.release()

        let images = [await first.value, await second.value]
        XCTAssertTrue(images.allSatisfy { $0 != nil })
        let requests = await script.requests
        XCTAssertEqual(requests.count, 1, "concurrent rows for the same icon must share one request")
    }

    @MainActor
    func testDecodedIconsAreServedFromCacheWithoutRefetch() async {
        let script = FetchScript()
        let loader = makeLoader(script)

        let first = await loader.image(for: Self.iconURL)
        let second = await loader.image(for: Self.iconURL)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 1, "a decoded icon must be a cache hit, not a refetch")
    }

    @MainActor
    func testGarbageDataResolvesToThePlaceholder() async {
        let script = FetchScript()
        await script.setPayload(Data("this is not an image".utf8))
        let loader = makeLoader(script)

        let image = await loader.image(for: Self.iconURL)

        XCTAssertNil(image, "undecodable data must resolve to nil — the placeholder, not an error state")
    }

    @MainActor
    func testHTTPErrorResolvesToThePlaceholder() async {
        let script = FetchScript()
        await script.setStatusCode(404)
        let loader = makeLoader(script)

        let image = await loader.image(for: Self.iconURL)

        XCTAssertNil(image, "an HTTP error page must never be decoded as an icon")
    }

    @MainActor
    func testLastWaiterCancellationCancelsTheFetchAndTheNextRequestStartsFresh() async {
        let script = FetchScript()
        await script.hold()
        let loader = makeLoader(script)

        let only = Task { await loader.image(for: Self.iconURL) }
        await script.waitUntilRequests(1)
        only.cancel()
        _ = await only.value

        await script.release()
        let retry = await loader.image(for: Self.iconURL)

        XCTAssertNotNil(retry, "a fresh request after cancellation must fetch again")
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        let cancelled = await script.cancelledFetches
        XCTAssertGreaterThan(cancelled, 0, "the abandoned fetch itself must be cancelled, not left running")
    }
}
