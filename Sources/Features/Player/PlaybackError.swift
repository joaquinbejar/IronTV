import Foundation

public enum PlaybackError: Error, LocalizedError {
    case invalidStreamURL
    case itemFailed(String)
    /// The panel advertises no container format this device can play and no
    /// trusted direct source for the stream.
    case noPlayableSource

    public var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            return "Could not build a playable URL for this channel."
        case .itemFailed(let message):
            return message
        case .noPlayableSource:
            return "This channel advertises no format this device can play."
        }
    }
}
