import CoreGraphics
import ImageIO
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
    func testOversizedIconsAreDownsampledToTheRowBound() async throws {
        // A provider-controlled 1000×1000 "icon" must never decode at full
        // resolution — the cache is memory-bounded only if decode is.
        let script = FetchScript()
        await script.setPayload(try Self.largePNG(side: 1000))
        let loader = makeLoader(script)

        let decoded = await loader.image(for: Self.iconURL)

        let image = try XCTUnwrap(decoded)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128,
                                 "decoded icon exceeds the thumbnail bound: \(image.width)×\(image.height)")
    }

    @MainActor
    func testRequestsAfterACancelledGenerationStillDedupe() async {
        // The regression: a cancelled generation finishing late must not
        // evict the newer in-flight entry for the same URL — concurrent
        // requests after the cancellation still share one fetch.
        let script = FetchScript()
        await script.hold()
        let loader = makeLoader(script)

        let first = Task { await loader.image(for: Self.iconURL) }
        await script.waitUntilRequests(1)
        first.cancel()
        _ = await first.value

        await script.hold()
        let second = Task { await loader.image(for: Self.iconURL) }
        let third = Task { await loader.image(for: Self.iconURL) }
        await script.waitUntilRequests(2)
        await script.release()

        let secondImage = await second.value
        let thirdImage = await third.value
        XCTAssertNotNil(secondImage)
        XCTAssertNotNil(thirdImage)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2, "the post-cancellation generation must still share one fetch")
    }

    /// Solid-color PNG of the given pixel side, built in-process.
    private static func largePNG(side: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("could not create a bitmap context") }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { throw XCTSkip("could not rasterize") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("could not encode a PNG") }
        return data as Data
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
