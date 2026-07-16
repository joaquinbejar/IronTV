import Foundation

/// Scope of the channel list: every channel on the panel, the user's
/// favorites, or one category.
public enum CategorySelection: Hashable, Sendable {
    case all
    case favorites
    case category(CategoryID)

    public var categoryID: CategoryID? {
        if case .category(let id) = self { return id }
        return nil
    }
}
