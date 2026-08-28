import SwiftUI

/// Transport controls for the VLC engine.
///
/// The Apple engine gets these for free — `AVPlayerView` on macOS and
/// `VideoPlayer` elsewhere both ship a transport bar. VLC's surface is a bare
/// drawable (`VLCPlayerSurface`), so a channel that falls back to VLC used to
/// lose play/pause, volume and mute on every platform, and lost them entirely
/// wherever the toolbar is dropped: full screen, iPhone landscape, tvOS.
///
/// Rendered as an `.overlay` on purpose. It must never take part in sizing the
/// video surface: changing that surface's bounds is what drives
/// `noteVideoSurfaceSize(_:)` and, past the material-change threshold, a VLC
/// geometry restart — so a control bar appearing would restart playback and
/// flash the video black. An overlay is laid out against its host's existing
/// frame and cannot do that.
///
/// No scrubber. These are live channels; a timeline the user can drag would
/// promise seeking that the stream does not support.
struct PlayerControlsOverlay: View {
    @ObservedObject var viewModel: PlayerViewModel

    /// tvOS has no pointer: the row has to be focusable and driven by the
    /// remote, and a continuous slider under the focus engine is hostile.
    /// Volume there is two steps instead.
    private static let volumeStep = 0.1

    var body: some View {
        HStack(spacing: 18) {
            playPauseButton
            liveButton
            Spacer(minLength: 12)
            muteButton
            volumeControl
        }
        #if !os(tvOS)
        // Not on tvOS: .plain strips the focus effect, and without the lift
        // and the ring the user cannot see which control the remote is on.
        .buttonStyle(.plain)
        #endif
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.vlcControls")
    }

    private var playPauseButton: some View {
        Button {
            viewModel.togglePlayPause()
        } label: {
            // Glyph carries the state; colour never does.
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
        }
        .help(isPaused ? "Resume" : "Pause")
        .accessibilityLabel(isPaused ? Text("Resume") : Text("Pause"))
        .accessibilityIdentifier("player.playPauseButton")
        // Not merely "is there a stream": loading, reconnecting and failed
        // render as neither playing nor paused, so a tap there would change
        // hidden state without changing the glyph.
        .disabled(!viewModel.canTogglePlayPause)
    }

    /// Pausing a live stream drifts it off the live edge; this is the way back.
    private var liveButton: some View {
        Button {
            viewModel.resyncToLive()
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
        }
        .help("Resync audio/video with the live stream")
        .accessibilityLabel(Text("Resync with the live stream"))
        .accessibilityIdentifier("player.liveButton")
        .disabled(viewModel.currentStream == nil)
    }

    private var muteButton: some View {
        Button {
            viewModel.toggleMute()
        } label: {
            Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .help(viewModel.isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(viewModel.isMuted ? Text("Unmute") : Text("Mute"))
        .accessibilityIdentifier("player.overlayMuteButton")
        .disabled(viewModel.currentStream == nil)
    }

    @ViewBuilder
    private var volumeControl: some View {
        #if os(tvOS)
        Button {
            viewModel.setVolume(viewModel.volume - Self.volumeStep)
        } label: {
            Image(systemName: "speaker.wave.1")
        }
        .help("Volume down")
        .accessibilityLabel(Text("Volume down"))
        .accessibilityIdentifier("player.volumeDownButton")
        .disabled(viewModel.currentStream == nil || viewModel.volume <= 0)

        Button {
            viewModel.setVolume(viewModel.volume + Self.volumeStep)
        } label: {
            Image(systemName: "speaker.wave.3")
        }
        .help("Volume up")
        .accessibilityLabel(Text("Volume up"))
        .accessibilityIdentifier("player.volumeUpButton")
        .disabled(viewModel.currentStream == nil || viewModel.volume >= 1)
        #else
        Slider(
            // Closure, not `set: viewModel.setVolume`. Passing the MainActor
            // method reference makes the compiler emit a reabstraction thunk
            // that crashes swift-frontend during IR generation (Swift 6.3.3).
            value: Binding(get: { viewModel.volume }, set: { viewModel.setVolume($0) }),
            in: 0...1
        )
        .frame(width: 110)
        .accessibilityLabel(Text("Volume"))
        .accessibilityIdentifier("player.volumeSlider")
        .disabled(viewModel.currentStream == nil)
        #endif
    }

    private var isPaused: Bool {
        viewModel.transport == .paused
    }
}
