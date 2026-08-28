import Foundation

/// The transport the user picked for a hand-entered account. Explicit rather
/// than inferred: it is what lets the host be a single field that accepts
/// `host` and `host:port` without anyone having to guess whether a missing
/// `https://` meant "plain HTTP is fine" or "I forgot to type it".
public enum TransportScheme: String, CaseIterable, Sendable {
    case https
    case http

    public var urlScheme: String { rawValue }
}

/// Why host/username/password typed by hand could not be turned into an
/// `Account`.
public enum CredentialFieldsError: Error, Equatable, LocalizedError {
    case missingHost
    /// The text is not usable as a host even after a scheme is added.
    case invalidHost
    /// A scheme was typed into the host field and contradicts the selector.
    case schemeMismatch(typed: String, selected: String)
    /// A scheme was typed and is neither http nor https.
    case unsupportedScheme(String)
    case missingUsername
    case missingPassword

    public var errorDescription: String? {
        switch self {
        case .missingHost:
            return String(localized: "Enter the server address your provider gave you.")
        case .invalidHost:
            return String(localized: "That server address can't be read. Use the form host.example.com or host.example.com:8080.")
        case .schemeMismatch(let typed, let selected):
            return String(localized: "The address starts with \(typed):// but \(selected) is selected. Change one of the two so they agree.")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported scheme “\(scheme)” — the address must use http or https.")
        case .missingUsername:
            return String(localized: "Enter your username.")
        case .missingPassword:
            return String(localized: "Enter your password.")
        }
    }
}

/// Builds an `Account` from separately entered host, username and password.
///
/// Deliberately does not go through ``M3UURLParser``. That parser has to guess
/// which query parameters carry the credentials, and Xtream panels disagree
/// about the spelling (`username` vs `user`, and others) — a list that can
/// never be complete. When the user hands the three values over separately
/// there is nothing left to guess, so nothing here parses a query string.
public enum CredentialFieldsParser {
    public static func parse(
        host rawHost: String,
        username rawUsername: String,
        password rawPassword: String,
        scheme: TransportScheme
    ) throws -> Account {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = try hostURL(from: rawHost, scheme: scheme)

        guard !username.isEmpty else { throw CredentialFieldsError.missingUsername }
        guard !password.isEmpty else { throw CredentialFieldsError.missingPassword }

        return Account(host: host, username: username, password: password)
    }

    /// Accepts `host`, `host:port`, and either form with a scheme already
    /// typed. Anything past the authority — a pasted `/get.php?…` tail — is
    /// dropped, the same way ``M3UURLParser`` rebuilds the host from scratch:
    /// the account host is a base for API URLs and a stray path would corrupt
    /// every one of them.
    static func hostURL(from rawHost: String, scheme: TransportScheme) throws -> URL {
        var text = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CredentialFieldsError.missingHost }

        if let separator = text.range(of: "://") {
            let typed = String(text[text.startIndex..<separator.lowerBound]).lowercased()
            guard typed == "http" || typed == "https" else {
                throw CredentialFieldsError.unsupportedScheme(typed)
            }
            guard typed == scheme.urlScheme else {
                throw CredentialFieldsError.schemeMismatch(typed: typed, selected: scheme.urlScheme)
            }
            text = String(text[separator.upperBound...])
        }

        // Authority only. Splitting here rather than letting URLComponents keep
        // the path is what makes a pasted playlist URL usable in this field.
        let authority = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !authority.isEmpty else { throw CredentialFieldsError.invalidHost }

        guard let parsed = URLComponents(string: "\(scheme.urlScheme)://\(authority)"),
              let parsedHost = parsed.host,
              !parsedHost.isEmpty
        else {
            throw CredentialFieldsError.invalidHost
        }

        var components = URLComponents()
        components.scheme = scheme.urlScheme
        components.host = parsedHost
        components.port = parsed.port
        guard let url = components.url else { throw CredentialFieldsError.invalidHost }
        return url
    }
}
