import Foundation

public enum XtreamAPIError: Error, LocalizedError {
    case invalidURL
    case network(URLError)
    case httpStatus(Int)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build a valid request URL for this panel."
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .httpStatus(let code):
            return "The panel answered with HTTP \(code)."
        case .decoding:
            return "The panel sent a response this app couldn't read."
        }
    }
}
