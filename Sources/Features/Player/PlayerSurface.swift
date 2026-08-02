import AVKit
import SwiftUI

/// Video surface wrapping AVPlayerView directly. SwiftUI's `VideoPlayer` is
/// avoided on purpose: its internal AVKit class fails Swift demangling during
/// AppKit state restoration on macOS 26 and aborts the process at launch.
#if os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    /// AVKit binds Picture in Picture to this view's `AVPlayer`. The VLC engine
    /// draws into a plain `NSView` drawable that AVKit cannot capture, so PiP is
    /// only offered while the Apple engine owns the surface — putting the VLC
    /// video in PiP would mean a custom sample-buffer implementation.
    var allowsPictureInPicture = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = allowsPictureInPicture
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        if view.allowsPictureInPicturePlayback != allowsPictureInPicture {
            view.allowsPictureInPicturePlayback = allowsPictureInPicture
        }
    }

    /// A Picture in Picture session outlives its host view by design. Without
    /// this, swapping the surface to VLC left a session bound to the AVPlayer
    /// that `PlayerViewModel.replacePlayer()` had just parked — a black PiP
    /// window while the main window happily kept playing. Ending the session
    /// along with the surface is what closes it.
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.allowsPictureInPicturePlayback = false
        nsView.player = nil
    }
}
#else
struct PlayerSurface: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
    }
}
#endif

/// Engine-aware video surface (AVPlayer or VLC), shared by the main player
/// view and the macOS floating mini-player.
struct EngineVideoSurface: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        #if canImport(VLCKitSPM)
        if viewModel.engine == .vlc {
            VLCPlayerSurface(viewModel: viewModel)
        } else {
            appleSurface
        }
        #else
        appleSurface
        #endif
    }

    /// The Apple engine's surface. Only macOS takes the Picture in Picture
    /// decision here — iOS/tvOS use `VideoPlayer`, which owns its own controls.
    private var appleSurface: some View {
        #if os(macOS)
        PlayerSurface(
            player: viewModel.player,
            allowsPictureInPicture: PlayerViewModel.allowsPictureInPicture(for: viewModel.engine)
        )
        #else
        PlayerSurface(player: viewModel.player)
        #endif
    }
}
