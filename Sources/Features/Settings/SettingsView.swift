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
            return String(localized: "License file missing from the app bundle.")
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                playlistURLField

                HStack {
                    Button("Validate & Save", action: submit)
                        .disabled(!viewModel.canSubmit)
                    Spacer()
                    statusView
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Paste the M3U playlist URL from your provider. IronTV only extracts the server and credentials from it — the playlist itself is never downloaded. The URL contains your password, so it is hidden while you type and cleared once the account is saved.")
                    .foregroundStyle(.secondary)
            }

            if let account = appModel.account {
                Section {
                    LabeledContent("Server", value: account.host.absoluteString)
                    LabeledContent("Username", value: account.username)
                    LabeledContent("Transport") {
                        // Deliberately scoped to the panel API: stream requests
                        // follow whatever URLs the panel serves and the media
                        // engines offer no redirect enforcement, so the app
                        // must not claim playback transport is secured.
                        if account.usesSecureTransport {
                            Label("HTTPS (panel API encrypted)", systemImage: "lock.fill")
                        } else {
                            Label("HTTP (unencrypted)", systemImage: "lock.open")
                                .foregroundStyle(.orange)
                        }
                    }
                    Button("Remove Account", role: .destructive) {
                        viewModel.removeAccount(from: appModel)
                    }
                } header: {
                    Text("Current account")
                } footer: {
                    Text("Stream playback follows the URLs your panel serves; their transport is controlled by the provider.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("This provider uses plain HTTP", isPresented: insecureConfirmationBinding) {
            Button("Continue with HTTP") {
                Task { await viewModel.confirmInsecureTransport(into: appModel) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelInsecureTransport()
            }
        } message: {
            Text("No HTTPS endpoint answered on this server. Over plain HTTP, anyone on the network path can read your username, password, and what you watch. Continue only if you accept that.")
        }
        .onDisappear { viewModel.formDismissed() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding can snapshot the window; don't leave a password
            // sitting in the field for it.
            if phase == .background {
                viewModel.formDismissed()
            }
        }
    }

    /// Obscured by default, with an explicit reveal. Both variants keep paste
    /// working and take the characters exactly as pasted — no autocorrection and
    /// no autocapitalization, which would corrupt a credential.
    @ViewBuilder
    private var playlistURLField: some View {
        let prompt = Text("http://host.example.com:8080/get.php?username=…&password=…")

        HStack {
            Group {
                if viewModel.isRevealingURL {
                    TextField("Playlist URL", text: $viewModel.urlText, prompt: prompt)
                } else {
                    SecureField("Playlist URL", text: $viewModel.urlText, prompt: prompt)
                }
            }
            .autocorrectionDisabled()
            #if os(iOS) || os(tvOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .textContentType(.URL)
            #endif
            .onSubmit(submit)

            revealToggle
        }
    }

    @ViewBuilder
    private var revealToggle: some View {
        let label = viewModel.isRevealingURL
            ? String(localized: "Hide playlist URL")
            : String(localized: "Show playlist URL")
        #if os(tvOS)
        // The focus engine needs a real, labelled control here.
        Button(viewModel.isRevealingURL ? "Hide" : "Show") { viewModel.toggleURLReveal() }
            .accessibilityLabel(label)
            .accessibilityIdentifier("settings.revealToggle")
        #else
        Button {
            viewModel.toggleURLReveal()
        } label: {
            Image(systemName: viewModel.isRevealingURL ? "eye.slash" : "eye")
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("settings.revealToggle")
        #endif
    }

    private func submit() {
        guard viewModel.canSubmit else { return }
        Task { await viewModel.validateAndSave(into: appModel) }
    }

    /// Presents the insecure-transport alert while the view model waits for a
    /// decision. A dismissal without a button (Esc, tap outside) only drops the
    /// presentation — an in-flight Continue action can still consume the
    /// pending confirmation.
    private var insecureConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.phase == .confirmingInsecureTransport },
            set: { presented in
                if !presented {
                    viewModel.insecureConfirmationDismissed()
                }
            }
        )
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
        case .confirmingInsecureTransport:
            // The alert carries the decision; the inline row just flags it.
            Label("Awaiting HTTP confirmation", systemImage: "lock.open")
                .foregroundStyle(.orange)
        case .success(let expiryDate):
            Label(successText(expiryDate: expiryDate), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func successText(expiryDate: Date?) -> String {
        SettingsViewModel.successMessage(expiryDate: expiryDate)
    }
}

// MARK: - Playback

struct PlaybackSettingsTab: View {
    @StateObject private var model = PlaybackSettingsModel()

    var body: some View {
        Form {
            Section {
                Picker("Playback engine", selection: $model.settings.preferredEngine) {
                    Text("Automatic").tag(PlaybackEngineOption.auto)
                    Text("Apple (HLS)").tag(PlaybackEngineOption.avplayer)
                    Text("VLC (MPEG-TS)").tag(PlaybackEngineOption.vlc)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Automatic starts with the Apple player and silently switches a channel to the VLC engine (raw MPEG-TS, like most IPTV apps) when it keeps stalling or uses unsupported codecs. The player shows which engine is active in its toolbar.")
                    .foregroundStyle(.secondary)
            }

            Section {
                secondsStepper(String(localized: "Forward buffer"), value: $model.settings.forwardBufferSeconds, in: PlaybackSettings.forwardBufferRange, step: 5)
                secondsStepper(String(localized: "Live delay (stall cushion)"), value: $model.settings.liveEdgeOffsetSeconds, in: PlaybackSettings.liveEdgeOffsetRange, step: 5)
                Toggle("Fast start (may stutter on weak connections)", isOn: $model.settings.fastStart)
            } header: {
                Text("Buffering (Apple engine)")
            } footer: {
                Text("These apply to the Apple engine only — the VLC engine uses a fixed 3-second network cache. A larger live delay starts playback further behind the live edge, absorbing network hiccups at the cost of being more seconds behind the broadcast; it is automatically capped to a third of the panel's live window.")
                    .foregroundStyle(.secondary)
            }
            .disabled(model.settings.preferredEngine == .vlc)

            Section {
                secondsStepper(String(localized: "Reconnect after buffering for"), value: $model.settings.waitingTimeoutSeconds, in: PlaybackSettings.waitingTimeoutRange, step: 1)
                secondsStepper(String(localized: "Reconnect after frozen video for"), value: $model.settings.frozenTimeoutSeconds, in: PlaybackSettings.frozenTimeoutRange, step: 1)
                secondsStepper(String(localized: "Health check interval"), value: $model.settings.watchdogIntervalSeconds, in: PlaybackSettings.watchdogIntervalRange, step: 1)
                intStepper(String(localized: "Fast reconnect attempts"), value: $model.settings.maxReconnectAttempts, in: PlaybackSettings.maxReconnectAttemptsRange)
            } header: {
                Text("Auto-reconnect")
            } footer: {
                Text("After the fast attempts, IronTV keeps retrying indefinitely at a slower, capped cadence — a live stream never gives up. Reconnect pacing applies to both engines; buffering and frozen-video detection are Apple-engine health checks.")
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                secondsStepper(String(localized: "API request timeout"), value: $model.settings.apiTimeoutSeconds, in: PlaybackSettings.apiTimeoutRange, step: 5)
            }

            Section {
                Button("Restore Defaults") {
                    model.restoreDefaults()
                }
            } footer: {
                Text("Changes apply from the next stream start or reconnect.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.reload()
        }
        .onChange(of: model.settings) { _, _ in
            // The model persists only genuine differences, so the round-trip
            // from a remote adoption is a no-op instead of nine stale writes.
            model.persist()
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
