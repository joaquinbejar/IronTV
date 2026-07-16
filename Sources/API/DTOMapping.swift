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
        return LiveStream(
            id: StreamID(id),
            name: name,
            iconURL: iconURL,
            categoryID: categoryID,
            epgChannelID: epgChannelId
        )
    }
}

public extension UserInfoDTO {
    func toDomain() -> AccountStatus {
        AccountStatus(
            authenticated: auth == 1,
            status: status,
            expiryDate: expDate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            maxConnections: maxConnections
        )
    }
}
