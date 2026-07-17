#if os(macOS)
import AppKit
import SwiftUI

/// Floating mini-player: a chromeless, resizable, always-on-top window with
/// nothing but the video. The main window hides while it's active and comes
/// back when the user exits (button or double-click).
@MainActor
final class FloatingPlayerManager: ObservableObject {
    @Published private(set) var isFloating = false

    private var window: NSWindow?
    private weak var hiddenMainWindow: NSWindow?
    private static let frameAutosaveName = "IronTVFloatingPlayer"

    func toggle(with viewModel: PlayerViewModel) {
        if isFloating {
            exit(viewModel: viewModel)
        } else {
            enter(viewModel: viewModel)
        }
    }

    func exitIfNeeded(viewModel: PlayerViewModel) {
        if isFloating {
            exit(viewModel: viewModel)
        }
    }

    private func enter(viewModel: PlayerViewModel) {
        guard window == nil else { return }

        let content = FloatingPlayerContent(viewModel: viewModel) { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            self.exit(viewModel: viewModel)
        }
        let hosting = NSHostingController(rootView: content)
        let floating = NSWindow(contentViewController: hosting)

        // Visually frameless, but titled under the hood: keeps edge-resizing,
        // window dragging, and frame autosaving working.
        floating.styleMask = [.titled, .resizable, .fullSizeContentView]
        floating.titleVisibility = .hidden
        floating.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            floating.standardWindowButton(button)?.isHidden = true
        }
        floating.isMovableByWindowBackground = true
        floating.level = .floating
        floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floating.backgroundColor = .black
        floating.contentAspectRatio = NSSize(width: 16, height: 9)
        floating.minSize = NSSize(width: 320, height: 180)
        floating.isReleasedWhenClosed = false

        if !floating.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main {
            let area = screen.visibleFrame
            floating.setFrame(
                NSRect(x: area.maxX - 500, y: area.minY + 40, width: 480, height: 270),
                display: true
            )
        }
        floating.setFrameAutosaveName(Self.frameAutosaveName)

        hiddenMainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0 !== floating }
        hiddenMainWindow?.orderOut(nil)

        floating.makeKeyAndOrderFront(nil)
        window = floating
        isFloating = true

        #if canImport(VLCKitSPM)
        // VLC renders into a concrete NSView — rebuild its output for the
        // floating window's surface.
        viewModel.videoSurfaceGeometryChanged()
        #endif
    }

    private func exit(viewModel: PlayerViewModel) {
        window?.saveFrame(usingName: Self.frameAutosaveName)
        window?.orderOut(nil)
        window = nil

        hiddenMainWindow?.makeKeyAndOrderFront(nil)
        hiddenMainWindow = nil
        isFloating = false

        #if canImport(VLCKitSPM)
        viewModel.videoSurfaceGeometryChanged()
        #endif
    }
}

/// Content of the floating window: the video plus a hover-only exit control.
private struct FloatingPlayerContent: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onExit: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            EngineVideoSurface(viewModel: viewModel)
                .ignoresSafeArea()

            transientStatus

            if hovering {
                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Return to the main window")
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onExit)
        .frame(minWidth: 320, minHeight: 180)
        .background(Color.black)
    }

    @ViewBuilder
    private var transientStatus: some View {
        switch viewModel.state {
        case .loading, .buffering, .reconnecting:
            ZStack {
                Color.clear
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
        default:
            EmptyView()
        }
    }
}
#endif
