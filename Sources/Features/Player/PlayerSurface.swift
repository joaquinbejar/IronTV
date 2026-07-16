import AVKit
import SwiftUI

/// Video surface wrapping AVPlayerView directly. SwiftUI's `VideoPlayer` is
/// avoided on purpose: its internal AVKit class fails Swift demangling during
/// AppKit state restoration on macOS 26 and aborts the process at launch.
#if os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
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
