import Foundation

/// Identifier of a live-stream category, as returned by `get_live_categories`.
public struct CategoryID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }
}

/// Identifier of a live stream, used in `get_live_streams` and playback URLs.
public struct StreamID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.init(rawValue: rawValue)
    }
}
