import XCTest
@testable import IronTV

/// The branch that replaces a dead end: a playlist URL whose credentials
/// cannot be parsed becomes an account whose catalog is the playlist itself.
final class PlaylistAccountBuilderTests: XCTestCase {

    func testKeepsTheWholeURLAsThePlaylistAndTrimsTheHost() throws {
        let account = try XCTUnwrap(
            PlaylistAccountBuilder.account(fromPlaylistURL: "http://host.example.com:8080/get.php?user=U&pass=P&type=m3u_plus")
        )
        XCTAssertEqual(account.origin, .playlist)
        XCTAssertEqual(account.host.absoluteString, "http://host.example.com:8080")
        XCTAssertEqual(
            account.playlistURL?.absoluteString,
            "http://host.example.com:8080/get.php?user=U&pass=P&type=m3u_plus"
        )
    }

    /// Nothing builds a URL from these for a playlist account, and inventing
    /// values would put them in the Keychain and in the preference namespace.
    func testUsernameAndPasswordStayEmpty() throws {
        let account = try XCTUnwrap(PlaylistAccountBuilder.account(fromPlaylistURL: "http://h/playlist.m3u"))
        XCTAssertEqual(account.username, "")
        XCTAssertEqual(account.password, "")
    }

    func testHTTPSIsPreserved() throws {
        let account = try XCTUnwrap(PlaylistAccountBuilder.account(fromPlaylistURL: "https://h/playlist.m3u"))
        XCTAssertTrue(account.usesSecureTransport)
    }

    func testRejectsWhatCannotBeDownloadedEither() {
        for input in ["", "   ", "not a url", "ftp://h/playlist.m3u", "rtmp://h/x"] {
            XCTAssertNil(PlaylistAccountBuilder.account(fromPlaylistURL: input), "input: \(input)")
        }
    }

    // MARK: - Account decoding

    /// Records written before playlist support existed are Xtream by
    /// construction; a missing key must not lock the user out of an account
    /// they already had.
    func testAccountsSavedBeforeTheOriginExistedDecodeAsXtream() throws {
        let legacy = Data("""
        {"host":"http://host.example.com:8080","username":"u","password":"p"}
        """.utf8)
        let account = try JSONDecoder().decode(Account.self, from: legacy)
        XCTAssertEqual(account.origin, .xtream)
        XCTAssertNil(account.playlistURL)
        XCTAssertTrue(account.reportsPanelStatus)
    }

    func testOriginSurvivesAKeychainRoundTrip() throws {
        let original = try XCTUnwrap(PlaylistAccountBuilder.account(fromPlaylistURL: "http://h:8080/get.php?x=1"))
        let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertFalse(restored.reportsPanelStatus)
    }
}
