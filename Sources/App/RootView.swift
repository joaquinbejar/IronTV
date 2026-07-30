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
            // Keyed by the full account identity — host, username and a
            // fingerprint of the password — so the browser, its XtreamClient
            // and its caches are rebuilt whenever any credential changes and
            // never keep serving the previous account.
            ChannelBrowserView(account: account)
                .id(account.identity)
        } else {
            // Full-window empty state — no split view, so it works on
            // compact (iPhone) layouts too.
            noAccountView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @EnvironmentObject private var appModel: AppModel
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
            Button("Try Sample Channels") {
                appModel.startSampleMode()
            }
            .buttonStyle(.bordered)
            Text("Sample channels play free public demo streams — no subscription needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
