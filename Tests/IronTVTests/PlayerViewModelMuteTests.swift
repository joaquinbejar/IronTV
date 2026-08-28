import AVKit
import XCTest
@testable import IronTV

/// Mute is engine-agnostic state that has to survive the player swaps the
/// view model performs underneath the surface. These tests cover the state
/// machine and the AVPlayer application; the VLC side shares the same
/// `applyMute()` call site and cannot be exercised without a real
/// `VLCMediaPlayer`, which needs a window server.
final class PlayerViewModelMuteTests: XCTestCase {

    @MainActor
    private func makeViewModel() -> PlayerViewModel {
        PlayerViewModel(settingsStore: PlaybackSettingsStore(storage: UserDefaults(suiteName: "PlayerVMMuteTests.\(UUID())")!))
    }

    @MainActor
    func testStartsUnmuted() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isMuted)
        XCTAssertFalse(viewModel.player.isMuted)
    }

    @MainActor
    func testToggleFlipsStateAndReachesTheApplePlayer() {
        let viewModel = makeViewModel()

        viewModel.toggleMute()
        XCTAssertTrue(viewModel.isMuted)
        XCTAssertTrue(viewModel.player.isMuted)

        viewModel.toggleMute()
        XCTAssertFalse(viewModel.isMuted)
        XCTAssertFalse(viewModel.player.isMuted)
    }

    @MainActor
    func testSetMutedIsIdempotent() {
        let viewModel = makeViewModel()

        viewModel.setMuted(true)
        viewModel.setMuted(true)
        XCTAssertTrue(viewModel.isMuted)
        XCTAssertTrue(viewModel.player.isMuted)
    }

    /// The regression this guards: `stop()` swaps in a fresh `AVPlayer`, which
    /// starts unmuted. Without re-applying, a muted channel came back loud on
    /// the next zap.
    @MainActor
    func testMuteSurvivesAPlayerSwap() {
        let viewModel = makeViewModel()
        viewModel.setMuted(true)
        let original = viewModel.player

        viewModel.stop()

        XCTAssertFalse(viewModel.player === original, "expected a fresh AVPlayer")
        XCTAssertTrue(viewModel.isMuted)
        XCTAssertTrue(viewModel.player.isMuted)
    }

    @MainActor
    func testUnmutedStateAlsoSurvivesAPlayerSwap() {
        let viewModel = makeViewModel()
        viewModel.setMuted(true)
        viewModel.setMuted(false)

        viewModel.stop()

        XCTAssertFalse(viewModel.isMuted)
        XCTAssertFalse(viewModel.player.isMuted)
    }
}
