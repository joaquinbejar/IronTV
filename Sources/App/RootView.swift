import SwiftUI

/// Root of the main window. NavigationSplitView-based so the layout stays
/// adaptive across macOS, iPadOS, iOS, and tvOS.
struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    #if !os(macOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        if let account = appModel.account {
            // Keyed by host so the browser fully resets on account change.
            ChannelBrowserView(account: account)
                .id(account.host)
        } else {
            NavigationSplitView {
                Text("No account")
                    .foregroundStyle(.secondary)
            } detail: {
                noAccountView
            }
            .navigationTitle("IronTV")
        }
    }

    @ViewBuilder
    private var noAccountView: some View {
        #if os(macOS)
        NoAccountView()
        #else
        NoAccountView {
            showingSettings = true
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        #endif
    }
}

/// Empty state shown until the user configures an account in Settings.
private struct NoAccountView: View {
    var openSettingsFallback: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No account configured")
                .font(.title3.bold())
            Text("Paste your provider's playlist URL in Settings to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            OpenSettingsButton(fallbackAction: openSettingsFallback)
        }
        .padding(40)
    }
}
