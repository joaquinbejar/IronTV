import Foundation

/// Provider credentials. Aggregate root; persisted in the Keychain.
public struct Account: Equatable, Codable, Sendable {
    /// Where this account's catalog comes from. Two sources, and the
    /// difference is visible to the user: a playlist account has no expiry
    /// date and no maximum-connections figure, because there is no panel to
    /// ask.
    public enum CatalogOrigin: String, Codable, Sendable {
        /// `player_api.php` — categories, streams and account status.
        case xtream
        /// The M3U file itself, for providers with no panel behind it.
        case playlist
    }

    /// Panel base URL: scheme + host + optional port, no path or query.
    public let host: URL
    public let username: String
    public let password: String
    /// Absent in accounts saved before playlist support existed, which are
    /// all Xtream by construction — decoding them must not fail.
    public let origin: CatalogOrigin
    /// The playlist to download, for ``CatalogOrigin/playlist`` accounts. Nil
    /// for Xtream accounts, whose URLs are built from host and credentials.
    public let playlistURL: URL?

    public init(
        host: URL,
        username: String,
        password: String,
        origin: CatalogOrigin = .xtream,
        playlistURL: URL? = nil
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.origin = origin
        self.playlistURL = playlistURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(URL.self, forKey: .host)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        // Keychain records written before this field existed decode as Xtream,
        // which is what they are. A missing key must never lock the user out
        // of an account they already had.
        origin = try container.decodeIfPresent(CatalogOrigin.self, forKey: .origin) ?? .xtream
        playlistURL = try container.decodeIfPresent(URL.self, forKey: .playlistURL)
    }
}

public extension Account {
    /// Whether panel traffic — credentials included — travels over TLS.
    var usesSecureTransport: Bool { host.scheme?.lowercased() == "https" }
}

public extension Account {
    /// Capabilities this account's source can actually report. The UI asks
    /// here rather than testing the origin at each call site, so a third
    /// source would not have to be chased through the views.
    var reportsPanelStatus: Bool { origin == .xtream }
}
