import Foundation

/// The Xtream surface the channel browser needs. A seam like
/// ``AccountValidating``: it lets `ChannelsViewModel` be exercised offline,
/// with scripted latencies and failures, which is what makes the
/// cancellation and dedup behavior testable.
public protocol ChannelBrowsing: Sendable {
    func accountStatus() async throws -> AccountStatus
    func liveCategories() async throws -> [Category]
    func liveStreams(in categoryID: CategoryID?) async throws -> [LiveStream]
    func playbackURL(for streamID: StreamID, format: XtreamClient.StreamFormat) throws -> URL
}

extension XtreamClient: ChannelBrowsing {}

public extension ChannelBrowsing {
    func playbackURL(for streamID: StreamID) throws -> URL {
        try playbackURL(for: streamID, format: .hls)
    }
}
