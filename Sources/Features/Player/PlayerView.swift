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

    var body: some View {
        if hidesChrome {
            core.ignoresSafeArea()
        } else {
            core
                .navigationTitle(viewModel.currentStream?.name ?? "IronTV")
                .toolbar {
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
    }

    private var core: some View {
        ZStack {
            PlayerSurface(player: viewModel.player)

            switch viewModel.state {
            case .idle:
                placeholder
            case .loading:
                ProgressView("Loading stream…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            case .buffering:
                ProgressView("Buffering…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            case .reconnecting:
                ProgressView("Reconnecting…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            case .playing:
                EmptyView()
            case .failed(let message):
                errorOverlay(message)
            }
        }
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
