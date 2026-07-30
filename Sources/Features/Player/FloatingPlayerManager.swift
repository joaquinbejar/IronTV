#if os(macOS)
import AppKit
import SwiftUI

/// Floating mini-player: a chromeless, resizable, always-on-top window with
/// nothing but the video. The source window hides while it's active and comes
/// back when the user exits.
///
/// Every way out converges on ``cleanUp(restoringSource:)``, which is
/// idempotent: the exit button, a double-click, Cmd-W or `performClose(_:)`
/// (through `windowWillClose`), the source window closing, and app termination.
/// Hiding the close button does not stop Cmd-W, so without that convergence the
/// app could be left with its main window ordered out, `isFloating` still true,
/// and no reachable window or recovery control.
@MainActor
final class FloatingPlayerManager: NSObject, ObservableObject {
    @Published private(set) var isFloating = false

    private var window: NSWindow?
    /// The window the user entered from — the one to hide and restore. Recorded
    /// explicitly via ``recordSourceWindow(_:)`` instead of picked out of
    /// `NSApp.windows`, where Settings is main-capable too.
    private weak var sourceWindow: NSWindow?
    /// The view model the floating window was entered with, so close paths that
    /// carry no argument (Cmd-W, termination) can still rebuild the VLC surface.
    private weak var activeViewModel: PlayerViewModel?
    private var observers: [NSObjectProtocol] = []
    private static let frameAutosaveName = "IronTVFloatingPlayer"

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Called by the browser as its window becomes known, so entering floating
    /// mode never has to guess which window to hide.
    func recordSourceWindow(_ window: NSWindow?) {
        guard let window else { return }
        sourceWindow = window
    }

    func toggle(with viewModel: PlayerViewModel) {
        if isFloating {
            cleanUp(restoringSource: true)
        } else {
            enter(viewModel: viewModel)
        }
    }

    func exitIfNeeded(viewModel: PlayerViewModel) {
        if isFloating {
            cleanUp(restoringSource: true)
        }
    }

    private func enter(viewModel: PlayerViewModel) {
        guard window == nil else { return }

        let content = FloatingPlayerContent(viewModel: viewModel) { [weak self] in
            self?.cleanUp(restoringSource: true)
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
        // Cmd-W and performClose(_:) close the window even with the close button
        // hidden; the delegate is what turns that into a full exit.
        floating.delegate = self

        if !floating.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main {
            let area = screen.visibleFrame
            floating.setFrame(
                NSRect(x: area.maxX - 500, y: area.minY + 40, width: 480, height: 270),
                display: true
            )
        }
        floating.setFrameAutosaveName(Self.frameAutosaveName)

        let source = sourceWindow ?? Self.fallbackSourceWindow(excluding: floating)
        sourceWindow = source
        source?.orderOut(nil)

        floating.makeKeyAndOrderFront(nil)
        window = floating
        activeViewModel = viewModel
        isFloating = true
        observeLifecycle(of: source)

        #if canImport(VLCKitSPM)
        // VLC renders into a concrete NSView — rebuild its output for the
        // floating window's surface.
        viewModel.videoSurfaceGeometryChanged()
        #endif
    }

    /// The single exit. Idempotent, so it is safe from any close path and safe to
    /// run twice — a Cmd-W that lands during the exit button's own teardown does
    /// nothing the second time.
    private func cleanUp(restoringSource: Bool) {
        let floating = window
        window = nil
        stopObserving()

        if let floating {
            floating.saveFrame(usingName: Self.frameAutosaveName)
            // Detach before ordering out: close() would otherwise re-enter
            // windowWillClose and run this again.
            floating.delegate = nil
            floating.orderOut(nil)
        }

        if restoringSource {
            restoreSourceWindow()
        }
        sourceWindow = nil
        isFloating = false

        #if canImport(VLCKitSPM)
        activeViewModel?.videoSurfaceGeometryChanged()
        #endif
        activeViewModel = nil
    }

    /// Bring back the exact window we hid. If it was closed while floating, fall
    /// back to any other main-capable window so the user is never left without
    /// one.
    private func restoreSourceWindow() {
        let restored = sourceWindow ?? Self.fallbackSourceWindow(excluding: window)
        restored?.makeKeyAndOrderFront(nil)
    }

    /// Only used when no source window was recorded — a main-capable window that
    /// isn't the floating one. Prefers the key window over an arbitrary pick.
    private static func fallbackSourceWindow(excluding floating: NSWindow?) -> NSWindow? {
        if let key = NSApp.keyWindow, key !== floating, key.canBecomeMain {
            return key
        }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0 !== floating }
    }

    private func observeLifecycle(of source: NSWindow?) {
        let center = NotificationCenter.default
        // Quitting while floating would otherwise persist a hidden main window
        // into the next launch's state restoration.
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanUp(restoringSource: true) }
        })

        guard let source else { return }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: source,
            queue: .main
        ) { [weak self] _ in
            // The window we hid is going away, so there is nothing to restore.
            // Keep the floating player up rather than leaving no window at all.
            MainActor.assumeIsolated { self?.sourceWindow = nil }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

// MARK: - NSWindowDelegate

extension FloatingPlayerManager: NSWindowDelegate {
    /// Cmd-W, performClose(_:), or anything else that closes the floating window
    /// behind our back. Without this the main window stayed ordered out and
    /// `isFloating` stayed true, leaving no way back.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        cleanUp(restoringSource: true)
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

/// Reports the window hosting the browser, so ``FloatingPlayerManager`` hides and
/// restores that exact window instead of picking one out of `NSApp.windows` —
/// where the Settings window is main-capable too and could be chosen instead.
struct HostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }
}
#endif
