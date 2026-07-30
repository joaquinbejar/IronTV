import Foundation

/// Refuses HTTP redirects that would move a credential-bearing request to a
/// different origin. Xtream API URLs carry the username and password in the
/// query, so a panel answering over HTTPS but redirecting to plain HTTP (or to
/// another host) would leak them before any user consent — exactly what the
/// insecure-transport confirmation exists to prevent.
///
/// A refused redirect surfaces as the redirect response itself, which the
/// client reports as `XtreamAPIError.httpStatus(3xx)` — a typed failure, not a
/// silent plaintext request.
final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = Self.allowsRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }

    /// Same origin means identical scheme, host, and effective port — a path
    /// change on the same panel is fine, an https→http downgrade or a host
    /// switch is not.
    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              let originalScheme = original.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              let originalHost = original.host?.lowercased(),
              let destinationHost = destination.host?.lowercased() else {
            return false
        }
        return originalScheme == destinationScheme
            && originalHost == destinationHost
            && effectivePort(scheme: originalScheme, port: original.port)
                == effectivePort(scheme: destinationScheme, port: destination.port)
    }

    private static func effectivePort(scheme: String, port: Int?) -> Int {
        if let port { return port }
        return scheme == "https" ? 443 : 80
    }
}
