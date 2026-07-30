#if canImport(VLCKitSPM)
import SwiftUI
import VLCKitSPM

/// Video surface for the VLC engine — channels whose codecs AVPlayer can't
/// decode, or whose HLS is too broken and play better as raw MPEG-TS.
#if os(macOS)
struct VLCPlayerSurface: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        viewModel.vlcPlayer?.drawable = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        viewModel.noteVideoSurfaceSize(nsView.bounds.size)
        if let player = viewModel.vlcPlayer, (player.drawable as? NSView) !== nsView {
            player.drawable = nsView
        }
    }
}
#else
struct VLCPlayerSurface: UIViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        viewModel.vlcPlayer?.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        viewModel.noteVideoSurfaceSize(uiView.bounds.size)
        if let player = viewModel.vlcPlayer, (player.drawable as? UIView) !== uiView {
            player.drawable = uiView
        }
    }
}
#endif
#endif
