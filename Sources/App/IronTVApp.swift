import SwiftUI

@main
struct IronTVApp: App {
    @StateObject private var appModel = AppModel()

    /// True when the app is only alive as a unit-test host — skip real UI
    /// (AVKit's VideoPlayer aborts the XCTest runner during bootstrap).
    private static let isTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.isTestHost {
                Text("Running tests")
            } else {
                RootView()
                    .environmentObject(appModel)
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
        #endif
    }
}
