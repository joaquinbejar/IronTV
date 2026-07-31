import SwiftUI

/// Screenshot deep links: `IRONTV_DEMO_SCREEN` drives the app straight to one
/// screen so App Store captures are deterministic. Every entry point is a
/// no-op outside demo mode.
enum DemoRouting {
    #if !os(tvOS)
    /// Desktop/touch routing. The iOS-only jumps (compact column, settings
    /// sheet) arrive as closures so macOS passes no-ops and the routing table
    /// stays in one place.
    @MainActor
    static func applyDesktopScreenIfNeeded(
        channels: ChannelsViewModel,
        player: PlayerViewModel,
        showChannelList: () -> Void,
        showPlayer: () -> Void,
        showSettings: () -> Void
    ) {
        guard DemoMode.isActive,
              let screen = ProcessInfo.processInfo.environment["IRONTV_DEMO_SCREEN"] else { return }
        switch screen {
        case "channels":
            channels.selectedCategory = .category(CategoryID(2)) // Sports
            showChannelList()
        case "favorites":
            channels.selectedCategory = .favorites
            showChannelList()
        case "player":
            channels.selectedCategory = .category(CategoryID(2))
            showPlayer()
            // Play the bundled demo clip directly — avoids the async
            // stream-load race that would leave the player idle.
            if let stream = DemoMode.streams(in: .category(CategoryID(2))).first(where: { $0.name == "Match Day FHD" }) {
                player.play(stream, url: DemoMode.screenshotClipURL)
            }
        case "settings":
            showSettings()
        default:
            break
        }
    }
    #endif

    #if os(tvOS)
    /// tvOS screenshot deep link (separate nav model from iOS/macOS).
    @MainActor
    static func applyTVScreenIfNeeded(path: inout NavigationPath) {
        guard DemoMode.isActive,
              let screen = ProcessInfo.processInfo.environment["IRONTV_DEMO_SCREEN"] else { return }
        switch screen {
        case "channels":
            path.append(CategorySelection.category(CategoryID(2)))
        case "favorites":
            path.append(CategorySelection.favorites)
        case "player":
            path.append(CategorySelection.category(CategoryID(2)))
            if let stream = DemoMode.streams(in: .category(CategoryID(2))).first(where: { $0.name == "Match Day FHD" }) {
                path.append(stream)
            }
        default:
            break
        }
    }
    #endif
}
