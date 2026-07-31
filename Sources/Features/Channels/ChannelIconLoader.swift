import Foundation
import ImageIO

/// Bounded, deduplicating loader for channel icons. `AsyncImage` gave every
/// row its own uncoordinated fetch against `URLCache.shared`; with a 50k-row
/// catalog that meant unbounded duplicate requests while scrolling. This
/// loader dedupes concurrent requests per URL, keeps decoded images in a
/// count-limited `NSCache`, and fetches through a dedicated session whose
/// `URLCache` is capped in memory and on disk — so icons can never crowd out
/// the app's other caching or grow without bound.
///
/// Decoded images are `CGImage` (immutable, `Sendable`), so decoding can run
/// off the main actor without isolation gymnastics.
@MainActor
final class ChannelIconLoader {
    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    static let shared = ChannelIconLoader()

    /// ~500 decoded icons at ≤128 px each is a handful of MB — enough that
    /// scrolling back through a long list is instant, small enough to be
    /// irrelevant next to the video buffers.
    private static let decodedImageLimit = 500
    /// Icons render at 28 points; 128 px covers that at any display scale
    /// with headroom. Provider-controlled data never decodes larger — a
    /// panel serving poster-sized "icons" costs the same as a real icon.
    /// nonisolated: read by the detached decode.
    private nonisolated static let maxIconPixelSize = 128
    /// Belt to the thumbnail's braces: even 500 worst-case thumbnails stay
    /// far under this, and the cost accounting means the cache is bounded in
    /// bytes, not just count, if the limits above ever drift.
    private static let decodedByteLimit = 32 * 1024 * 1024

    private struct Entry {
        var task: Task<CGImage?, Never>
        var waiters: Int
        /// Identity of this fetch generation. A cancelled task's late
        /// `finishLoad` and a stale waiter's `unsubscribe` must only touch
        /// the entry they belong to — never a newer one for the same URL.
        let token: UUID
    }

    private let cache = NSCache<NSURL, CGImage>()
    private var inFlight: [URL: Entry] = [:]
    private let fetch: Fetch

    /// The default fetch goes through a session dedicated to icons: 8 MB of
    /// memory / 64 MB of disk, `returnCacheDataElseLoad` because a channel
    /// icon that was good yesterday is good today — panels routinely send
    /// no-cache headers that would otherwise force a refetch storm on every
    /// launch. `fetch` is injectable so tests run fully offline.
    init(fetch: Fetch? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 8 * 1024 * 1024,
                diskCapacity: 64 * 1024 * 1024,
                directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                    .first?.appendingPathComponent("ChannelIcons", isDirectory: true)
            )
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration)
            self.fetch = { try await session.data(from: $0) }
        }
        cache.countLimit = Self.decodedImageLimit
        cache.totalCostLimit = Self.decodedByteLimit
    }

    /// The decoded icon, or nil for any failure — a broken icon renders as
    /// the placeholder, never as an error state. Concurrent callers for the
    /// same URL share one fetch; a caller cancelled mid-await (row scrolled
    /// off screen) unsubscribes, and the underlying request is cancelled
    /// once its last waiter is gone.
    func image(for url: URL) async -> CGImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let (task, token) = subscribe(url)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.unsubscribe(url, token: token) }
        }
    }

    private func subscribe(_ url: URL) -> (Task<CGImage?, Never>, UUID) {
        if var entry = inFlight[url] {
            entry.waiters += 1
            inFlight[url] = entry
            return (entry.task, entry.token)
        }
        let token = UUID()
        let fetch = self.fetch
        let task = Task { [weak self] () -> CGImage? in
            var image: CGImage?
            if let (data, response) = try? await fetch(url),
               (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true {
                image = await Task.detached { Self.decode(data) }.value
            }
            self?.finishLoad(of: url, token: token, with: image)
            return image
        }
        inFlight[url] = Entry(task: task, waiters: 1, token: token)
        return (task, token)
    }

    private func finishLoad(of url: URL, token: UUID, with image: CGImage?) {
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        // A cancelled generation finishing late must not evict the entry a
        // newer request installed for the same URL — that would break the
        // dedupe accounting and spawn duplicate fetches.
        guard inFlight[url]?.token == token else { return }
        inFlight[url] = nil
    }

    private func unsubscribe(_ url: URL, token: UUID) {
        guard var entry = inFlight[url], entry.token == token else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inFlight[url] = nil
        } else {
            inFlight[url] = entry
        }
    }

    /// ImageIO thumbnail decode to an immutable `CGImage`, capped at
    /// ``maxIconPixelSize`` — provider-controlled data must never dictate
    /// decoded size. nil for anything that isn't an image. Runs detached —
    /// decoding is the CPU cost worth keeping off the main actor, not the
    /// network wait.
    private nonisolated static func decode(_ data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxIconPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
