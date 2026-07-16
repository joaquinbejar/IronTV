import Foundation

/// One element of the `get_live_categories` array.
public struct LiveCategoryDTO: Decodable, Equatable {
    @FlexibleInt public var categoryId: Int?
    @FlexibleString public var categoryName: String?
    @FlexibleInt public var parentId: Int?

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }
}
