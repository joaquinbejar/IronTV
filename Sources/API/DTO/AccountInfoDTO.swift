import Foundation

/// `player_api.php` with no action: `{ "user_info": {...}, "server_info": {...} }`.
public struct AccountInfoDTO: Decodable, Equatable {
    public let userInfo: UserInfoDTO?
    public let serverInfo: ServerInfoDTO?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

public struct UserInfoDTO: Decodable, Equatable {
    @FlexibleString public var username: String?
    @FlexibleString public var message: String?
    @FlexibleInt public var auth: Int?
    @FlexibleString public var status: String?
    /// Unix timestamp; arrives as Int, String, or null (never-expiring trials).
    @FlexibleInt public var expDate: Int?
    @FlexibleString public var isTrial: String?
    @FlexibleInt public var activeCons: Int?
    @FlexibleInt public var createdAt: Int?
    @FlexibleInt public var maxConnections: Int?
    public var allowedOutputFormats: [String]?

    enum CodingKeys: String, CodingKey {
        case username
        case message
        case auth
        case status
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case createdAt = "created_at"
        case maxConnections = "max_connections"
        case allowedOutputFormats = "allowed_output_formats"
    }
}

public struct ServerInfoDTO: Decodable, Equatable {
    @FlexibleString public var url: String?
    @FlexibleInt public var port: Int?
    @FlexibleInt public var httpsPort: Int?
    @FlexibleString public var serverProtocol: String?
    @FlexibleInt public var rtmpPort: Int?
    @FlexibleString public var timezone: String?
    @FlexibleInt public var timestampNow: Int?
    @FlexibleString public var timeNow: String?

    enum CodingKeys: String, CodingKey {
        case url
        case port
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case rtmpPort = "rtmp_port"
        case timezone
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }
}
