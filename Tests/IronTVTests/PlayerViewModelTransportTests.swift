import AVKit
import XCTest
@testable import IronTV

/// The pause and volume state the VLC control bar drives, exercised through
/// the view model. The VLC side shares these call sites but needs a real
/// `VLCMediaPlayer`; the AVPlayer side is asserted directly.
final class PlayerViewModelTransportTests: XCTestCase {

    @MainActor
    private func makeViewModel() -> PlayerViewModel {
        PlayerViewModel(settingsStore: PlaybackSettingsStore(storage: UserDefaults(suiteName: "PlayerVMTransportTests.\(UUID())")!))
    }

    private let stream = LiveStream(id: StreamID(7), name: "Ch", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil)

    @MainActor
    private func primed() -> PlayerViewModel {
        let viewModel = makeViewModel()
        viewModel.primeForReconnectTesting(
            stream: stream,
            // Inert on purpose. This test needs a URL, not a credential
            // layout: scripts/secret-scan.sh flags `/live/{user}/{pass}/` in
            // tracked files unless the host is one of its allowlisted
            // example domains, and there is no reason to rely on that here.
            url: URL(string: "http://host.example.com/stream/7.m3u8")!,
            tsURL: nil,
            settings: PlaybackSettings.default,
            state: .playing
        )
        return viewModel
    }

    @MainActor
    func testStartsPlayingAndNotPaused() {
        let viewModel = primed()
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.transport, .playing)
    }

    @MainActor
    func testTogglePlayPauseFlipsBothWays() {
        let viewModel = primed()

        viewModel.togglePlayPause()
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertEqual(viewModel.transport, .paused)

        viewModel.togglePlayPause()
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.transport, .playing)
    }

    /// The tvOS remote reaches `setPaused` without going through the control
    /// bar, so the guard has to live in the view model too — not only in the
    /// button's `disabled`.
    @MainActor
    func testPauseIsIgnoredWhileReconnecting() {
        let viewModel = primed()
        viewModel.primeForReconnectTesting(
            stream: stream,
            url: URL(string: "http://host.example.com/stream/7.m3u8")!,
            tsURL: nil,
            settings: PlaybackSettings.default,
            state: .reconnecting
        )

        viewModel.togglePlayPause()

        XCTAssertFalse(viewModel.isPaused, "a recovering session must not be paused behind the user's back")
        XCTAssertEqual(viewModel.transport, .reconnecting)
    }

    /// Without a stream there is nothing to pause, and a latched `isPaused`
    /// would show a play button that does nothing on the next channel.
    @MainActor
    func testPauseIsIgnoredWithoutAStream() {
        let viewModel = makeViewModel()
        viewModel.togglePlayPause()
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.transport, .unavailable)
    }

    @MainActor
    func testStopClearsThePause() {
        let viewModel = primed()
        viewModel.togglePlayPause()

        viewModel.stop()

        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.transport, .unavailable)
    }

    @MainActor
    func testVolumeStartsAtFullAndReachesTheApplePlayer() {
        let viewModel = primed()
        XCTAssertEqual(viewModel.volume, 1, accuracy: 0.001)
        XCTAssertEqual(viewModel.player.volume, 1, accuracy: 0.001)

        viewModel.setVolume(0.4)
        XCTAssertEqual(viewModel.volume, 0.4, accuracy: 0.001)
        XCTAssertEqual(viewModel.player.volume, 0.4, accuracy: 0.001)
    }

    /// The tvOS step buttons walk the value by 0.1 and must not run past the
    /// ends, where AVPlayer would clamp silently and VLC would not.
    @MainActor
    func testVolumeIsClampedToZeroAndOne() {
        let viewModel = primed()

        viewModel.setVolume(-0.5)
        XCTAssertEqual(viewModel.volume, 0, accuracy: 0.001)

        viewModel.setVolume(1.8)
        XCTAssertEqual(viewModel.volume, 1, accuracy: 0.001)
    }

    @MainActor
    func testVolumeSurvivesAPlayerSwap() {
        let viewModel = primed()
        viewModel.setVolume(0.25)

        viewModel.stop()

        XCTAssertEqual(viewModel.volume, 0.25, accuracy: 0.001)
        XCTAssertEqual(viewModel.player.volume, 0.25, accuracy: 0.001)
    }
}
