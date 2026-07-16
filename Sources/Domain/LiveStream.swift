import Foundation

/// A live TV channel.
public struct LiveStream: Equatable, Hashable, Identifiable, Sendable {
    public let id: StreamID
    public let name: String
    public let iconURL: URL?
    public let categoryID: CategoryID
    public let epgChannelID: String?

    public init(id: StreamID, name: String, iconURL: URL?, categoryID: CategoryID, epgChannelID: String?) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.categoryID = categoryID
        self.epgChannelID = epgChannelID
    }
}
