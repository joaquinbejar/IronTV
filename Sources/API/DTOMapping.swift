import Foundation

// DTO -> domain mapping. Rows missing the fields a domain type cannot live
// without (id, name) are dropped rather than surfaced as broken entries.

public extension LiveCategoryDTO {
    func toDomain() -> Category? {
        guard let id = categoryId, let name = categoryName else { return nil }
        return Category(id: CategoryID(id), name: name)
    }
}

public extension LiveStreamDTO {
    /// `fallbackCategoryID` covers panels that omit `category_id` in
    /// per-category responses, where the caller already knows the category.
    func toDomain(fallbackCategoryID: CategoryID? = nil) -> LiveStream? {
        guard let id = streamId, let name = name else { return nil }
        guard let categoryID = categoryId.map({ CategoryID($0) }) ?? fallbackCategoryID else { return nil }
        let iconURL = streamIcon
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            .flatMap { $0.scheme == nil ? nil : $0 }
        // direct_source survives only as a well-formed absolute URL; the trust
        // policy (scheme + panel host) is applied by PlaybackSourcePlanner.
        let directSourceURL = directSource
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            .flatMap { $0.scheme == nil ? nil : $0 }
        return LiveStream(
            id: StreamID(id),
            name: name,
            iconURL: iconURL,
            categoryID: categoryID,
            epgChannelID: epgChannelId,
            directSourceURL: directSourceURL
        )
    }
}

public extension AccountInfoDTO {
    /// Authentication state comes from `user_info`, the advertised TLS port
    /// from `server_info` — combined here so callers get one domain value. A
    /// payload with no `user_info` is an unauthenticated status, port or not.
    func toAccountStatus() -> AccountStatus {
        let base = userInfo?.toDomain()
            ?? AccountStatus(authenticated: false, status: nil, expiryDate: nil, maxConnections: nil)
        return AccountStatus(
            authenticated: base.authenticated,
            status: base.status,
            expiryDate: base.expiryDate,
            maxConnections: base.maxConnections,
            allowedOutputFormats: base.allowedOutputFormats,
            advertisedHTTPSPort: Self.sanitizedHTTPSPort(serverInfo?.httpsPort)
        )
    }

    /// Panels put anything in `https_port`: 0 when TLS is off, the plain http
    /// port, negative or overflowing garbage. Only a valid TCP port survives;
    /// everything else means "no advertised TLS endpoint".
    private static func sanitizedHTTPSPort(_ raw: Int?) -> Int? {
        guard let raw, (1...65535).contains(raw) else { return nil }
        return raw
    }
}

public extension UserInfoDTO {
    func toDomain() -> AccountStatus {
        AccountStatus(
            authenticated: auth == 1,
            status: status,
            expiryDate: Self.sanitizedExpiryDate(expDate),
            maxConnections: maxConnections,
            allowedOutputFormats: Self.outputFormats(from: allowedOutputFormats)
        )
    }

    /// Panels report "never expires" inconsistently: `null`, a missing key, `0`,
    /// or negative garbage. All of those — plus values outside a plausible
    /// 2000-01-01…2100-01-01 window (tiny positives, millisecond-scale
    /// timestamps) — map to `nil`, meaning no known expiry. Plausible *past*
    /// timestamps survive, so a genuinely expired account stays distinguishable
    /// from a never-expiring one.
    /// Normalizes the panel's advertised formats: lowercased, unknown strings
    /// ignored. An absent field maps to nil (callers assume both classic
    /// formats); a present-but-unrecognizable list maps to an empty set — the
    /// panel said something, and it wasn't a format we can play.
    private static func outputFormats(from raw: [String]?) -> Set<StreamOutputFormat>? {
        guard let raw else { return nil }
        return Set(raw.compactMap { StreamOutputFormat(rawValue: $0.lowercased()) })
    }

    private static func sanitizedExpiryDate(_ raw: Int?) -> Date? {
        let plausibleUnixSeconds = 946_684_800...4_102_444_800
        guard let raw, plausibleUnixSeconds.contains(raw) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(raw))
    }
}
