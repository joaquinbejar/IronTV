import Foundation

/// Panel-side state of an account, from `player_api.php` `user_info`.
public struct AccountStatus: Equatable, Sendable {
    public let authenticated: Bool
    public let status: String?
    public let expiryDate: Date?
    public let maxConnections: Int?
    /// Container formats the panel advertises (`allowed_output_formats`).
    /// nil when the panel doesn't send the field — callers assume both
    /// classic formats then (see `PlaybackSourcePlanner`).
    public let allowedOutputFormats: Set<StreamOutputFormat>?
    /// TCP port the panel says its TLS endpoint listens on (`server_info.
    /// https_port`). nil when absent or not a valid port — panels put 0,
    /// negative garbage, or the http port here. Advisory only: callers must
    /// verify the endpoint actually authenticates before trusting it.
    public let advertisedHTTPSPort: Int?
    /// Scheme the panel claims to serve its API over (`server_info.
    /// server_protocol`), normalized to "http"/"https"; nil for absent or
    /// unrecognized values. Advisory like the port: the upgrade flow trusts
    /// only an endpoint it has verified, never this claim.
    public let advertisedScheme: String?

    public init(
        authenticated: Bool,
        status: String?,
        expiryDate: Date?,
        maxConnections: Int?,
        allowedOutputFormats: Set<StreamOutputFormat>? = nil,
        advertisedHTTPSPort: Int? = nil,
        advertisedScheme: String? = nil
    ) {
        self.authenticated = authenticated
        self.status = status
        self.expiryDate = expiryDate
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.advertisedHTTPSPort = advertisedHTTPSPort
        self.advertisedScheme = advertisedScheme
    }
}
