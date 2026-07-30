import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Platform dispatcher for the channel browser. Owns the two view models and
/// the scene/window lifecycle — playback start on selection, teardown, the
/// background slot release, macOS full-screen tracking and the floating
/// player's source window — and hands presentation to the pointer/touch
/// shell (macOS/iOS) or the focus-driven shell (tvOS).
struct ChannelBrowserView: View {
    @StateObject private var channels: ChannelsViewModel
    @StateObject private var player = PlayerViewModel()
    @Environment(\.scenePhase) private var scenePhase
    #if !os(tvOS)
    @State private var isFullScreen = false
    #endif
    #if os(macOS)
    @StateObject private var floatingManager = FloatingPlayerManager()
    #endif

    init(account: Account) {
        _channels = StateObject(wrappedValue: ChannelsViewModel(account: account))
    }

    var body: some View {
        content
            .onChange(of: channels.selectedStreamID) { _, streamID in
                // tvOS navigates by pushing screens; playback starts there.
                #if !os(tvOS)
                guard streamID != nil, let stream = channels.selectedStream() else { return }
                let coordinator = PlaybackCoordinator(channels: channels, player: player)
                Task { await coordinator.startPlayback(of: stream) }
                #endif
            }
            .onDisappear {
                #if os(macOS)
                floatingManager.exitIfNeeded(viewModel: player)
                #endif
                player.stop()
            }
            #if !os(macOS)
            .onChange(of: scenePhase) { _, phase in
                // Background = release the provider slot and every reconnect
                // task; a suspended scene must not hold a live connection.
                // `.inactive` is transient (app switcher, control center) and
                // deliberately ignored. Resume policy: no auto-play — the
                // selection is retained, replay is one tap (documented).
                if phase == .background {
                    player.stop()
                    // Re-arm the one-tap replay: with the selection cleared,
                    // tapping the same row is a real change and re-enters the
                    // playback path. The last-channel store already remembers
                    // the stream, so nothing is lost.
                    channels.selectedStreamID = nil
                }
            }
            #endif
            #if os(macOS)
            // Hand the floating player this window explicitly, so entering
            // mini-player mode hides and restores the browser rather than
            // whichever main-capable window AppKit happens to list first.
            .background(HostWindowReader { floatingManager.recordSourceWindow($0) })
            // Track macOS full screen regardless of how it was triggered
            // (our button, green button, or Ctrl+Cmd+F).
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isFullScreen = false
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        TVBrowserShell(channels: channels, player: player)
        #elseif os(macOS)
        DesktopBrowserShell(
            channels: channels,
            player: player,
            isFullScreen: $isFullScreen,
            floatingManager: floatingManager
        )
        #else
        DesktopBrowserShell(channels: channels, player: player, isFullScreen: $isFullScreen)
        #endif
    }
}
