#if canImport(VLCKitSPM) && !os(macOS)
import SwiftUI
import VLCKitSPM

/// Video surface for the VLC fallback engine — channels whose codecs
/// AVPlayer can't decode on this platform (MP2 audio, interlaced video).
struct VLCPlayerSurface: UIViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        viewModel.vlcPlayer?.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let player = viewModel.vlcPlayer, (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
    }
}
#endif
