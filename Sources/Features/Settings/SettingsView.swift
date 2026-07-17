import SwiftUI

/// Shown in the macOS Settings scene (Cmd+,). Pure SwiftUI so the same forms
/// can later be presented as sheets or tabs on iOS.
struct SettingsView: View {
    #if !os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        settingsTabs
            .frame(minWidth: 520, minHeight: 340)
        #else
        // Presented as a sheet on iOS/tvOS — needs its own Done button.
        NavigationStack {
            settingsTabs
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #endif
    }

    private var settingsTabs: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            LicenseTab()
                .tabItem { Label("License", systemImage: "doc.text") }
        }
    }
}

// MARK: - License

struct LicenseTab: View {
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License file missing from the app bundle."
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            #if !os(tvOS)
                .textSelection(.enabled)
            #endif
        }
    }
}

// MARK: - Account

struct AccountSettingsTab: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section {
                TextField(
                    "Playlist URL",
                    text: $viewModel.urlText,
                    prompt: Text("http://host.example.com:8080/get.php?username=…&password=…")
                )
                .autocorrectionDisabled()
                .onSubmit(submit)

                HStack {
                    Button("Validate & Save", action: submit)
                        .disabled(!viewModel.canSubmit)
                    Spacer()
                    statusView
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Paste the M3U playlist URL from your provider. IronTV only extracts the server and credentials from it — the playlist itself is never downloaded.")
                    .foregroundStyle(.secondary)
            }

            if let account = appModel.account {
                Section("Current account") {
                    LabeledContent("Server", value: account.host.absoluteString)
                    LabeledContent("Username", value: account.username)
                    Button("Remove Account", role: .destructive) {
                        viewModel.removeAccount(from: appModel)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func submit() {
        guard viewModel.canSubmit else { return }
        Task { await viewModel.validateAndSave(into: appModel) }
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.phase {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 6) {
                #if os(tvOS)
                ProgressView()
                #else
                ProgressView().controlSize(.small)
                #endif
                Text("Validating…").foregroundStyle(.secondary)
            }
        case .success(let expiryDate):
            Label(successText(expiryDate: expiryDate), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func successText(expiryDate: Date?) -> String {
        guard let expiryDate else { return "Account valid" }
        return "Account valid until \(expiryDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Playback

struct PlaybackSettingsTab: View {
    private let store = PlaybackSettingsStore()
    @State private var settings = PlaybackSettings.default

    var body: some View {
        Form {
            Section {
                secondsStepper("Forward buffer", value: $settings.forwardBufferSeconds, in: 5...120, step: 5)
                secondsStepper("Live delay (stall cushion)", value: $settings.liveEdgeOffsetSeconds, in: 0...60, step: 5)
                Toggle("Fast start (may stutter on weak connections)", isOn: $settings.fastStart)
            } header: {
                Text("Buffering")
            } footer: {
                Text("A larger live delay starts playback further behind the live edge, absorbing network hiccups at the cost of being more seconds behind the broadcast.")
                    .foregroundStyle(.secondary)
            }

            Section("Auto-reconnect") {
                secondsStepper("Reconnect after buffering for", value: $settings.waitingTimeoutSeconds, in: 2...60, step: 1)
                secondsStepper("Reconnect after frozen video for", value: $settings.frozenTimeoutSeconds, in: 2...60, step: 1)
                secondsStepper("Health check interval", value: $settings.watchdogIntervalSeconds, in: 1...10, step: 1)
                intStepper("Max reconnect attempts", value: $settings.maxReconnectAttempts, in: 1...10)
            }

            Section("Network") {
                secondsStepper("API request timeout", value: $settings.apiTimeoutSeconds, in: 5...120, step: 5)
            }

            Section {
                Button("Restore Defaults") {
                    store.reset()
                    settings = store.load()
                }
            } footer: {
                Text("Changes apply from the next stream start or reconnect.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settings = store.load()
        }
        .onChange(of: settings) { newValue in
            store.save(newValue)
        }
    }

    private func secondsStepper(
        _ title: String,
        value: Binding<TimeInterval>,
        in range: ClosedRange<TimeInterval>,
        step: TimeInterval
    ) -> some View {
        #if os(tvOS)
        // Stepper doesn't exist on tvOS — focusable +/- buttons instead.
        AdjusterRow(title: title, valueText: "\(Int(value.wrappedValue)) s") { delta in
            let updated = value.wrappedValue + TimeInterval(delta) * step
            value.wrappedValue = min(max(updated, range.lowerBound), range.upperBound)
        }
        #else
        Stepper(value: value, in: range, step: step) {
            LabeledContent(title, value: "\(Int(value.wrappedValue)) s")
        }
        #endif
    }

    private func intStepper(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>
    ) -> some View {
        #if os(tvOS)
        AdjusterRow(title: title, valueText: "\(value.wrappedValue)") { delta in
            value.wrappedValue = min(max(value.wrappedValue + delta, range.lowerBound), range.upperBound)
        }
        #else
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue)")
        }
        #endif
    }
}

#if os(tvOS)
/// tvOS replacement for Stepper: a row with focusable −/+ buttons.
private struct AdjusterRow: View {
    let title: String
    let valueText: String
    let adjust: (Int) -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("−") { adjust(-1) }
                .buttonStyle(.bordered)
            Text(valueText)
                .monospacedDigit()
                .frame(minWidth: 70)
            Button("+") { adjust(1) }
                .buttonStyle(.bordered)
        }
    }
}
#endif
