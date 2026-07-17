import Foundation

/// Fictional catalog used only for App Store screenshots, so captures never
/// show a real provider's channel names. Activated with the `IRONTV_DEMO=1`
/// launch environment variable — never reachable in a shipped build.
enum DemoMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["IRONTV_DEMO"] == "1"
    }

    static let account = Account(
        host: URL(string: "http://demo.irontv.local")!,
        username: "demo",
        password: "demo"
    )

    static let categories: [Category] = [
        Category(id: CategoryID(1), name: "News"),
        Category(id: CategoryID(2), name: "Sports"),
        Category(id: CategoryID(3), name: "Movies"),
        Category(id: CategoryID(4), name: "Documentary"),
        Category(id: CategoryID(5), name: "Kids"),
        Category(id: CategoryID(6), name: "Music"),
    ]

    private static let byCategory: [CategoryID: [String]] = [
        CategoryID(1): ["World News 24", "Morning Report HD", "Global Affairs", "Local News One"],
        CategoryID(2): ["Sports Central HD", "Match Day FHD", "Court & Field", "Motor Weekly", "Arena Live"],
        CategoryID(3): ["Cinema Prime", "Indie Screen", "Classic Reels", "Action Now HD"],
        CategoryID(4): ["Nature & Beyond", "History Deep Dive", "Science Today"],
        CategoryID(5): ["Cartoon Corner", "Little Explorers", "Story Time HD"],
        CategoryID(6): ["Hit Radio TV", "Jazz Lounge", "Classical Hall"],
    ]

    static func streams(in selection: CategorySelection) -> [LiveStream] {
        switch selection {
        case .all:
            return categories.flatMap { streams(in: .category($0.id)) }
        case .favorites:
            return favoriteIDs.compactMap { id in allStreams.first { $0.id == id } }
        case .category(let id):
            let names = byCategory[id] ?? []
            return names.enumerated().map { index, name in
                LiveStream(
                    id: StreamID(id.rawValue * 100 + index),
                    name: name,
                    iconURL: nil,
                    categoryID: id,
                    epgChannelID: nil
                )
            }
        }
    }

    static let favoriteIDs: Set<StreamID> = [StreamID(200), StreamID(301), StreamID(100)]

    private static var allStreams: [LiveStream] {
        categories.flatMap { streams(in: .category($0.id)) }
    }

    /// Bundled sample clip so the player screen shows real playback UI.
    static var sampleStreamURL: URL {
        Bundle.main.url(forResource: "demo_stream", withExtension: "mp4")
            ?? URL(string: "http://demo.irontv.local/none.m3u8")!
    }
}
