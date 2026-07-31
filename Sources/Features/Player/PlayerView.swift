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
                    ToolbarItem {
                        Button(action: toggleFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Toggle Full Screen")
                        .accessibilityLabel("Toggle full screen")
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
