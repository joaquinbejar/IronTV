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

/// Playlist accounts carry an empty username and a host reduced to the
/// authority, so identity has to come from somewhere else or two playlists on
/// one server become the same account.
final class PlaylistAccountIdentityTests: XCTestCase {

    private func playlist(_ url: String) throws -> Account {
        try XCTUnwrap(PlaylistAccountBuilder.account(fromPlaylistURL: url))
    }

    func testTwoPlaylistsOnTheSameHostAreDifferentAccounts() throws {
        let a = try playlist("http://host.example.com/a.m3u")
        let b = try playlist("http://host.example.com/b.m3u")

        XCTAssertNotEqual(a.identity, b.identity)
        XCTAssertNotEqual(a.identity.storageNamespace, b.identity.storageNamespace,
                          "favorites and last channel would otherwise share a namespace")
        XCTAssertNotEqual(a.identity.fingerprint, b.identity.fingerprint,
                          "the browser would otherwise keep the previous catalog on switching")
    }

    func testTheSamePlaylistKeepsTheSameIdentity() throws {
        let first = try playlist("http://host.example.com/a.m3u")
        let again = try playlist("http://host.example.com/a.m3u")
        XCTAssertEqual(first.identity, again.identity)
    }

    /// The playlist URL carries the provider's credentials, so it may reach a
    /// preference key or a log only as an irreversible digest.
    func testThePlaylistURLNeverAppearsInAnIdentityString() throws {
        let account = try playlist("http://host.example.com/get.php?user=topsecretuser&pass=topsecretpass")
        for text in [account.identity.namespace, account.identity.storageNamespace,
                     account.identity.fingerprint, account.identity.description] {
            XCTAssertFalse(text.contains("topsecretuser"), "credential leaked into \(text)")
            XCTAssertFalse(text.contains("topsecretpass"), "credential leaked into \(text)")
            XCTAssertFalse(text.contains("get.php"), "playlist path leaked into \(text)")
        }
    }

    /// Existing Xtream accounts must derive exactly as before, or every user's
    /// favorites and last channel detach from their account on update.
    func testXtreamIdentitiesAreUnchanged() throws {
        let account = Account(host: URL(string: "http://host.example.com:8080")!, username: "user1", password: "pass1")
        let identity = account.identity

        XCTAssertEqual(identity.namespace, "http://host.example.com:8080.user1")
        XCTAssertEqual(
            identity,
            AccountIdentity(host: account.host, username: "user1", password: "pass1"),
            "the playlist-free initializer must stay byte-identical"
        )
    }
}
