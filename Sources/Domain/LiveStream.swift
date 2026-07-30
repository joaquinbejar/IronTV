import Foundation

/// A live TV channel.
public struct LiveStream: Equatable, Hashable, Identifiable, Sendable {
    public let id: StreamID
    public let name: String
    public let iconURL: URL?
    public let categoryID: CategoryID
    public let epgChannelID: String?
    /// Provider-supplied playback URL (`direct_source`). Carried as-is here;
    /// the trust policy (scheme + same panel host) is applied by
    /// ``PlaybackSourcePlanner`` before it can ever reach an engine.
    public let directSourceURL: URL?

    public init(
        id: StreamID,
        name: String,
        iconURL: URL?,
        categoryID: CategoryID,
        epgChannelID: String?,
        directSourceURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.categoryID = categoryID
        self.epgChannelID = epgChannelID
        self.directSourceURL = directSourceURL
    }
}
