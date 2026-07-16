import Foundation

/// Panel-side state of an account, from `player_api.php` `user_info`.
public struct AccountStatus: Equatable, Sendable {
    public let authenticated: Bool
    public let status: String?
    public let expiryDate: Date?
    public let maxConnections: Int?

    public init(authenticated: Bool, status: String?, expiryDate: Date?, maxConnections: Int?) {
        self.authenticated = authenticated
        self.status = status
        self.expiryDate = expiryDate
        self.maxConnections = maxConnections
    }
}
