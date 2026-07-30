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

    public init(
        authenticated: Bool,
        status: String?,
        expiryDate: Date?,
        maxConnections: Int?,
        allowedOutputFormats: Set<StreamOutputFormat>? = nil
    ) {
        self.authenticated = authenticated
        self.status = status
        self.expiryDate = expiryDate
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
    }
}
