import XCTest
@testable import IronTV

/// The channel-list toggle is view state, so what is testable here is the
/// contract around it rather than the layout: that hiding the list is not the
/// same thing as full screen, and that the video surface is told to rebuild.
///
/// The swap itself needs a running window server, so the visual result — no
/// black frame on the VLC engine after the transition — belongs to the manual
/// pass, the same as the full-screen swap it copies.
final class ChannelListVisibilityTests: XCTestCase {

    @MainActor
    private func makeViewModel() -> PlayerViewModel {
        PlayerViewModel(settingsStore: PlaybackSettingsStore(storage: UserDefaults(suiteName: "ChannelListTests.\(UUID())")!))
    }

    /// `videoSurfaceRecreated()` is what stops VLC rendering black into a
    /// drawable that no longer exists. It must be safe to call when there is
    /// nothing playing, because the user can hide the list before picking a
    /// channel.
    @MainActor
    func testSurfaceRecreationIsSafeWithNoStream() {
        let viewModel = makeViewModel()
        XCTAssertNil(viewModel.currentStream)

        viewModel.videoSurfaceRecreated()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.currentStream)
    }

    /// Hiding the list keeps the toolbar, so it must not disturb playback the
    /// way stopping would: the same stream is still current afterwards.
    @MainActor
    func testSurfaceRecreationKeepsTheCurrentStream() {
        let viewModel = makeViewModel()
        let stream = LiveStream(id: StreamID(3), name: "Ch", iconURL: nil, categoryID: CategoryID(1), epgChannelID: nil)
        viewModel.primeForReconnectTesting(
            stream: stream,
            url: URL(string: "http://example.test/live/u/p/3.m3u8")!,
            tsURL: nil,
            settings: .default,
            state: .playing
        )

        viewModel.videoSurfaceRecreated()

        XCTAssertEqual(viewModel.currentStream, stream)
    }
}
