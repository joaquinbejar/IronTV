import XCTest
@testable import IronTV

/// The transport controls render from `PlayerViewModel.transport`, a pure
/// mapping of playback state plus the user's pause. Keeping it pure is what
/// makes the VLC control bar testable at all: the engine itself needs a
/// window server.
final class PlayerTransportStateTests: XCTestCase {

    private func transport(
        _ state: PlayerViewModel.State,
        paused: Bool = false,
        hasStream: Bool = true
    ) -> PlayerViewModel.Transport {
        PlayerViewModel.transport(for: state, isPaused: paused, hasStream: hasStream)
    }

    func testNoStreamIsUnavailableWhateverTheState() {
        for state: PlayerViewModel.State in [.idle, .loading, .playing, .buffering, .reconnecting, .failed("x")] {
            XCTAssertEqual(transport(state, hasStream: false), .unavailable, "state \(state)")
        }
    }

    func testIdleIsUnavailableEvenWithAStream() {
        XCTAssertEqual(transport(.idle), .unavailable)
    }

    func testStatesMapStraightThroughWhenNotPaused() {
        XCTAssertEqual(transport(.loading), .loading)
        XCTAssertEqual(transport(.playing), .playing)
        XCTAssertEqual(transport(.buffering), .buffering)
        XCTAssertEqual(transport(.reconnecting), .reconnecting)
        XCTAssertEqual(transport(.failed("boom")), .failed)
    }

    func testPauseOutranksPlaying() {
        XCTAssertEqual(transport(.playing, paused: true), .paused)
    }

    /// The reason pause outranks buffering: VLC emits `.buffering` constantly,
    /// including while paused. Letting it win would flicker the button back to
    /// "pause" under the user's finger, reading as a lost tap.
    func testPauseOutranksBuffering() {
        XCTAssertEqual(transport(.buffering, paused: true), .paused)
    }

    // MARK: - Actionability

    /// The glyph is derived from the transport state, so a toggle in a state
    /// that renders as neither playing nor paused would flip hidden state
    /// without changing the icon — and would reach pause() on a player that is
    /// still opening or recovering.
    func testPlayPauseIsOnlyActionableWhereTheGlyphReflectsIt() {
        XCTAssertTrue(PlayerViewModel.canTogglePlayPause(.playing))
        XCTAssertTrue(PlayerViewModel.canTogglePlayPause(.paused))
        XCTAssertTrue(PlayerViewModel.canTogglePlayPause(.buffering))

        XCTAssertFalse(PlayerViewModel.canTogglePlayPause(.unavailable))
        XCTAssertFalse(PlayerViewModel.canTogglePlayPause(.loading))
        XCTAssertFalse(PlayerViewModel.canTogglePlayPause(.reconnecting))
        XCTAssertFalse(PlayerViewModel.canTogglePlayPause(.failed))
    }

    /// A pause must not disguise a session that is in trouble — the user needs
    /// to see reconnecting and failed even if they had paused first.
    func testPauseDoesNotMaskReconnectingOrFailure() {
        XCTAssertEqual(transport(.reconnecting, paused: true), .reconnecting)
        XCTAssertEqual(transport(.failed("boom"), paused: true), .failed)
        XCTAssertEqual(transport(.loading, paused: true), .loading)
    }
}
