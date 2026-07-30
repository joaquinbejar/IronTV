import Foundation

public enum XtreamAPIError: Error, LocalizedError {
    case invalidURL
    case network(URLError)
    case httpStatus(Int)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Could not build a valid request URL for this panel.")
        case .network(let underlying):
            return String(localized: "Network error: \(underlying.localizedDescription)")
        case .httpStatus(let code):
            let codeText = "\(code)"
            return String(localized: "The panel answered with HTTP \(codeText).")
        case .decoding:
            return String(localized: "The panel sent a response this app couldn't read.")
        }
    }
}
