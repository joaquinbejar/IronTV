import Foundation

/// Why a pasted playlist URL could not be turned into an `Account`.
public enum M3UURLParseError: Error, Equatable, LocalizedError {
    /// Input is empty or not parseable as a URL with a scheme and host.
    case notAURL
    /// URL parses but its scheme is not http/https (e.g. ftp, rtmp).
    case unsupportedScheme(String)
    /// No non-empty `username` query parameter.
    case missingUsername
    /// No non-empty `password` query parameter.
    case missingPassword

    public var errorDescription: String? {
        switch self {
        case .notAURL:
            return String(localized: "This doesn't look like a URL. Paste the full playlist URL from your provider.")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported scheme “\(scheme)” — the playlist URL must start with http:// or https://.")
        case .missingUsername:
            return String(localized: "The URL has no username parameter.")
        case .missingPassword:
            return String(localized: "The URL has no password parameter.")
        }
    }
}

/// Extracts Xtream credentials from the M3U playlist URL handed out by
/// providers, e.g. `http://host:8080/get.php?username=U&password=P&type=m3u_plus`.
/// The URL is only a credential container — the M3U file is never fetched.
public enum M3UURLParser {
    public static func parse(_ input: String) throws -> Account {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else {
            throw M3UURLParseError.notAURL
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw M3UURLParseError.notAURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw M3UURLParseError.unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw M3UURLParseError.notAURL
        }

        let query = components.queryItems ?? []
        func value(named name: String) -> String? {
            query.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let username = value(named: "username"), !username.isEmpty else {
            throw M3UURLParseError.missingUsername
        }
        guard let password = value(named: "password"), !password.isEmpty else {
            throw M3UURLParseError.missingPassword
        }

        var hostComponents = URLComponents()
        hostComponents.scheme = scheme
        hostComponents.host = host
        hostComponents.port = components.port
        guard let hostURL = hostComponents.url else {
            throw M3UURLParseError.notAURL
        }
        return Account(host: hostURL, username: username, password: password)
    }
}
