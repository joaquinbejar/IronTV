import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Opens Settings from the empty state. On macOS this targets the Settings
/// scene (SettingsLink on 14+, the responder-chain selector on 13). On other
/// platforms the caller presents SettingsView as a sheet via `fallbackAction`.
struct OpenSettingsButton: View {
    var fallbackAction: () -> Void = {}

    var body: some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Open Settings…")
            }
        } else {
            Button("Open Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        #else
        Button("Open Settings…", action: fallbackAction)
        #endif
    }
}
