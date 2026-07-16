import Foundation

/// A live-stream category shown in the sidebar.
public struct Category: Equatable, Hashable, Identifiable, Sendable {
    public let id: CategoryID
    public let name: String

    public init(id: CategoryID, name: String) {
        self.id = id
        self.name = name
    }
}
