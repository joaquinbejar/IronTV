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
                    ToolbarItem {
                        Button {
                            viewModel.resyncToLive()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .help("Resync audio/video with the live stream")
                        .disabled(viewModel.currentStream == nil)
                    }
                    #if os(macOS)
                    ToolbarItem {
                        Button(action: toggleFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Toggle Full Screen")
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
            .onChange(of: chromeHidden) { _ in
                // Wait for the rotation animation to settle — restarting VLC
                // against mid-rotation bounds sizes the video for the old
                // orientation (small video in a black frame).
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    viewModel.videoSurfaceGeometryChanged()
                }
            }
        #endif
    }

    /// Brief rebuffers are invisible: the buffering/reconnecting overlay only
    /// appears when the interruption lasts longer than this.
    private static let overlayDelay: UInt64 = 1_500_000_000
    @State private var showTransientOverlay = false

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
        .onChange(of: viewModel.state) { state in
            switch state {
            case .buffering, .reconnecting:
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.overlayDelay)
                    if viewModel.state == .buffering || viewModel.state == .reconnecting {
                        showTransientOverlay = true
                    }
                }
            default:
                showTransientOverlay = false
            }
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        #if canImport(VLCKitSPM)
        if viewModel.engine == .vlc {
            VLCPlayerSurface(viewModel: viewModel)
        } else {
            PlayerSurface(player: viewModel.player)
        }
        #else
        PlayerSurface(player: viewModel.player)
        #endif
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
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
