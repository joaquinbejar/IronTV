import SwiftUI

@main
struct IronTVApp: App {
    @StateObject private var appModel = AppModel()

    /// True when the app is only alive as a unit-test host — skip real UI
    /// (AVKit's VideoPlayer aborts the XCTest runner during bootstrap).
    private static let isTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Single-playback-scene policy (documented decision, issue #10): one
    /// browser+player scene per app, because every playback window consumes a
    /// provider connection slot and Xtream panels enforce low max_connections.
    /// macOS uses a unique `Window` (no Cmd+N, no duplicate-window menu
    /// items); iPadOS declares UIApplicationSupportsMultipleScenes=false in
    /// project.yml. The floating mini-player is a child of this scene, not a
    /// second one.
    var body: some Scene {
        #if os(macOS)
        Window("IronTV", id: "main") {
            if Self.isTestHost {
                Text("Running tests")
            } else {
                RootView()
                    .environmentObject(appModel)
            }
        }
        .commands {
            // A second window would be a second provider connection.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
        #else
        WindowGroup {
            if Self.isTestHost {
                Text("Running tests")
            } else {
                RootView()
                    .environmentObject(appModel)
            }
        }
        #endif
    }
}
