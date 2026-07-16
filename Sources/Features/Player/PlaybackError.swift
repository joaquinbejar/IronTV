import Foundation

public enum PlaybackError: Error, LocalizedError {
    case invalidStreamURL
    case itemFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            return "Could not build a playable URL for this channel."
        case .itemFailed(let message):
            return message
        }
    }
}
