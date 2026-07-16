import Foundation

/// Xtream Codes credentials, parsed from the M3U URL the user pastes in
/// Settings. Aggregate root; persisted in the Keychain.
public struct Account: Equatable, Codable, Sendable {
    /// Panel base URL: scheme + host + optional port, no path or query.
    public let host: URL
    public let username: String
    public let password: String

    public init(host: URL, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }
}
