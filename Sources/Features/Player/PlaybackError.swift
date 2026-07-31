import Foundation

public enum PlaybackError: Error, LocalizedError {
    case invalidStreamURL
    case itemFailed(String)
    /// The panel advertises no container format this device can play and no
    /// trusted direct source for the stream.
    case noPlayableSource
    /// The stream's media requests moved to an insecure or different server
    /// than the planned origin — playback is stopped rather than keep sending
    /// credential-bearing requests there.
    case insecureTransport

    public var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            return String(localized: "Could not build a playable URL for this channel.")
        case .itemFailed(let message):
            return message
        case .noPlayableSource:
            return String(localized: "This channel advertises no format this device can play.")
        case .insecureTransport:
            return String(localized: "Playback was stopped: the stream tried to move to an insecure or different server.")
        }
    }
}
