import Foundation

/// The one path from a selected channel to a running engine, shared by every
/// platform surface: the split-view selection on macOS/iOS and the pushed
/// player screen on tvOS. Resolves the capabilities-aware plan asynchronously
/// and lets the result through only if the selection still points at the same
/// stream when the plan arrives — a stale plan must neither start audio for a
/// channel the user already left nor overwrite a fresher failure.
@MainActor
struct PlaybackCoordinator {
    private let channels: ChannelsViewModel
    private let onPlay: @MainActor (LiveStream, ChannelsViewModel.PlaybackPlan) -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(channels: ChannelsViewModel, player: PlayerViewModel) {
        self.init(
            channels: channels,
            onPlay: { player.play($0, url: $1.primaryURL, tsURL: $1.tsURL, hlsAvailable: $1.hlsAvailable) },
            onFailure: { player.fail($0) }
        )
    }

    /// Seam for tests: the engine side is two closures, so the coordination
    /// logic is observable without ever creating an AVPlayer.
    init(
        channels: ChannelsViewModel,
        onPlay: @escaping @MainActor (LiveStream, ChannelsViewModel.PlaybackPlan) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.channels = channels
        self.onPlay = onPlay
        self.onFailure = onFailure
    }

    /// Plans and starts playback of `stream`. The plan may await the panel's
    /// capabilities fetch, so both outcomes — start and failure — are gated
    /// on the selection still being current.
    func startPlayback(of stream: LiveStream) async {
        do {
            let plan = try await channels.playbackPlan(for: stream.id)
            guard channels.selectedStreamID == stream.id else { return }
            onPlay(stream, plan)
        } catch {
            guard channels.selectedStreamID == stream.id else { return }
            onFailure(error)
        }
    }
}
