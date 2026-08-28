import AVKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// Invoked when the user asks for full screen, before the window toggles,
    /// so the browser chrome can hide without waiting for AppKit notifications.
    var onWillToggleFullScreen: (() -> Void)? = nil
    /// macOS floating mini-player toggle; the toolbar button only appears
    /// when this is provided.
    var onToggleFloating: (() -> Void)? = nil
    /// Full-screen mode: no navigation title, no toolbar, edge-to-edge video.
    var hidesChrome: Bool = false

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// iPhone landscape (compact vertical size class) is full-screen video —
    /// no explicit toggle needed, just rotate the phone.
    private var chromeHidden: Bool {
        #if os(iOS)
        return hidesChrome || verticalSizeClass == .compact
        #else
        return hidesChrome
        #endif
    }

    var body: some View {
        // One stable hierarchy: branching here would recreate the video
        // surface on rotation and VLC's output goes black when its drawable
        // is torn down mid-playback.
        core
            .ignoresSafeArea(.all, edges: chromeHidden ? .all : [])
            // No navigation title in full screen — on tvOS it renders a large
            // channel-name overlay across the video.
            .navigationTitle(chromeHidden ? "" : (viewModel.currentStream?.name ?? "IronTV"))
            .toolbar {
                if !chromeHidden {
                    // Non-intrusive diagnostic: which engine is actually
                    // playing, so Automatic's silent VLC fallback is visible
                    // and the engine-scoped settings make sense.
                    if viewModel.currentStream != nil {
                        ToolbarItem {
                            Text(viewModel.engine == .vlc ? "VLC" : "Apple")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                // Text-based so Spanish VoiceOver gets the
                                // catalog translation, not the raw String.
                                .accessibilityLabel(viewModel.engine == .vlc
                                    ? Text("Playing with the VLC engine")
                                    : Text("Playing with the Apple engine"))
                                .accessibilityIdentifier("player.engineChip")
                        }
                    }
                    ToolbarItem {
                        Button {
                            viewModel.toggleMute()
                        } label: {
                            // Glyph, not colour: the state has to be readable
                            // without relying on hue.
                            Image(systemName: viewModel.isMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill")
                        }
                        .help(viewModel.isMuted ? "Unmute" : "Mute")
                        // Text-based so Spanish VoiceOver gets the catalog
                        // translation, and state-announcing so the label says
                        // what the button will do.
                        .accessibilityLabel(viewModel.isMuted ? Text("Unmute") : Text("Mute"))
                        .accessibilityIdentifier("player.muteButton")
                        .disabled(viewModel.currentStream == nil)
                        #if os(macOS)
                        // Shift too: plain Cmd-M is AppKit's Minimize, and
                        // taking it would cost the window its standard verb.
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        #endif
                    }
                    ToolbarItem {
                        Button {
                            viewModel.resyncToLive()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .help("Resync audio/video with the live stream")
                        .accessibilityLabel("Resync with the live stream")
                        .accessibilityIdentifier("player.resyncButton")
                        .disabled(viewModel.currentStream == nil)
                    }
                    #if os(macOS)
                    if let onToggleFloating {
                        ToolbarItem {
                            Button(action: onToggleFloating) {
                                Image(systemName: "pip.swap")
                            }
                            .help("Floating mini player (always on top)")
                            .accessibilityLabel("Floating mini player")
                            .accessibilityIdentifier("player.floatingButton")
                            .disabled(viewModel.currentStream == nil)
                        }
                    }
                    #endif
                    #if os(macOS) || os(iOS)
                    // iPhone landscape is already edge-to-edge, but iPad —
                    // and iPhone portrait — need an explicit way in.
                    ToolbarItem {
                        Button(action: toggleFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Toggle Full Screen")
                        // Same key as the help text: keys differing only in
                        // case collide in Xcode's generated catalog symbols
                        // and break Product → Archive.
                        .accessibilityLabel("Toggle Full Screen")
                        .accessibilityIdentifier("player.fullScreenButton")
                    }
                    #endif
                }
            }
        #if os(tvOS)
            .toolbar(chromeHidden ? .hidden : .automatic, for: .navigationBar)
        #endif
        #if os(iOS)
            .statusBarHidden(chromeHidden)
            .toolbar(chromeHidden ? .hidden : .automatic, for: .navigationBar)
            .task(id: GeometryRestartKey(chromeHidden: chromeHidden, generation: viewModel.playbackGeneration)) {
                // Wait for the rotation animation to settle — restarting VLC
                // against mid-rotation bounds sizes the video for the old
                // orientation (small video in a black frame). task(id:) makes
                // this cancellable: a newer geometry change, a channel/engine
                // change (generation bump), or disappearance kills the
                // pending restart instead of letting it fire on a newer
                // playback. The view model additionally skips restarts whose
                // surface size didn't materially change.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                viewModel.videoSurfaceGeometryChanged()
            }
        #endif
    }

    /// Brief rebuffers are invisible: the buffering/reconnecting overlay only
    /// appears when the interruption lasts longer than this.
    private static let overlayDelay: UInt64 = 1_500_000_000
    @State private var showTransientOverlay = false
    /// Auto-hiding engine badge for chrome-less surfaces (tvOS player screen,
    /// full-screen) where the toolbar chip is unreachable.
    @State private var showEngineBadge = false

    /// VLC transport controls: shown on interaction, hidden again after a
    /// pause. The token restarts the hide countdown on every reveal, so the
    /// bar does not vanish while the user is still using it.
    @State private var showVLCControls = false
    @State private var vlcControlsRevealToken = 0
    private static let vlcControlsLinger: UInt64 = 4_000_000_000

    /// Only the VLC engine needs these: AVPlayerView and VideoPlayer bring
    /// their own transport bar, and a second one over them would fight it.
    private var wantsVLCControls: Bool {
        viewModel.engine == .vlc && viewModel.currentStream != nil
    }

    private func revealVLCControls() {
        guard wantsVLCControls else { return }
        showVLCControls = true
        vlcControlsRevealToken &+= 1
    }

    private struct VLCControlsKey: Equatable {
        let token: Int
        let wanted: Bool
    }

    private var core: some View {
        ZStack {
            videoSurface

            switch viewModel.state {
            case .idle:
                placeholder
            case .loading:
                ProgressView("Loading stream…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            case .buffering:
                if showTransientOverlay {
                    ProgressView("Buffering…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            case .reconnecting:
                if showTransientOverlay {
                    ProgressView("Reconnecting…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            case .playing:
                EmptyView()
            case .failed(let message):
                errorOverlay(message)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showEngineBadge, viewModel.currentStream != nil {
                // Ternary at the Text level, not inside one Text(String) —
                // these keys have Spanish translations that must resolve.
                (viewModel.engine == .vlc ? Text("VLC engine") : Text("Apple engine"))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityLabel(viewModel.engine == .vlc
                        ? Text("Playing with the VLC engine")
                        : Text("Playing with the Apple engine"))
            }
        }
        .overlay(alignment: .bottom) {
            if wantsVLCControls, showVLCControls {
                PlayerControlsOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showVLCControls)
        // Reveal on any deliberate interaction. Simultaneous rather than
        // exclusive so the Apple engine's own controls keep receiving taps.
        .simultaneousGesture(TapGesture().onEnded { revealVLCControls() })
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { revealVLCControls() }
        }
        #endif
        #if os(tvOS)
        // The remote's play/pause button is the primary transport on tvOS,
        // and it has to work whether or not the bar is currently on screen.
        .onPlayPauseCommand {
            guard wantsVLCControls else { return }
            // Reveal regardless — showing the user why nothing happened beats
            // a remote press that appears to do nothing at all.
            revealVLCControls()
            guard viewModel.canTogglePlayPause else { return }
            viewModel.togglePlayPause()
        }
        .onMoveCommand { _ in revealVLCControls() }
        #endif
        .task(id: VLCControlsKey(token: vlcControlsRevealToken, wanted: wantsVLCControls)) {
            // Same shape as the engine badge: bound to the transition, so a
            // newer reveal (or leaving VLC) cancels the pending hide instead
            // of letting an orphan timer close the bar under the user.
            guard wantsVLCControls, showVLCControls else {
                showVLCControls = false
                return
            }
            try? await Task.sleep(nanoseconds: Self.vlcControlsLinger)
            guard !Task.isCancelled else { return }
            showVLCControls = false
        }
        .task(id: EngineBadgeKey(engine: viewModel.engine, generation: viewModel.playbackGeneration)) {
            // Chrome-less surfaces have no toolbar chip: show the active
            // engine briefly on every session/engine change, then fade out.
            guard chromeHidden, viewModel.currentStream != nil else {
                showEngineBadge = false
                return
            }
            showEngineBadge = true
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            showEngineBadge = false
        }
        .task(id: viewModel.state) {
            // Bound to the exact transition: every state change cancels the
            // pending delay, so no orphan sleep can flip the overlay after
            // the transition (or the view) is gone.
            switch viewModel.state {
            case .buffering, .reconnecting:
                try? await Task.sleep(nanoseconds: Self.overlayDelay)
                guard !Task.isCancelled else { return }
                if viewModel.state == .buffering || viewModel.state == .reconnecting {
                    showTransientOverlay = true
                }
            default:
                showTransientOverlay = false
            }
        }
    }

    private var videoSurface: some View {
        EngineVideoSurface(viewModel: viewModel)
    }

    private func toggleFullScreen() {
        #if os(macOS)
        let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        guard let window else { return }
        onWillToggleFullScreen?()
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        #elseif os(iOS)
        // No window mode to toggle here — the browser shell swaps its
        // hierarchy to the bare player and provides the exit control.
        onWillToggleFullScreen?()
        #endif
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.tv")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Select a channel to start watching")
                .foregroundStyle(.secondary)
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
            Text("Playback failed")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Retry") {
                viewModel.retry()
            }
            .accessibilityIdentifier("player.retryButton")
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Identity for the pending VLC geometry restart: a change in either field
/// cancels the previous delay via `.task(id:)`.
private struct GeometryRestartKey: Equatable {
    let chromeHidden: Bool
    let generation: UInt64
}

/// Identity for the auto-hiding engine badge: re-shown on every engine or
/// session change.
private struct EngineBadgeKey: Equatable {
    let engine: PlayerViewModel.Engine
    let generation: UInt64
}
