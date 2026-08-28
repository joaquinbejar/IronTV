import XCTest
@testable import IronTV

/// Building an `Account` from separately entered values. The point of this
/// path is that nothing is guessed: no query string is parsed, so the
/// parameter-name disagreement between panels (`username` vs `user`, and the
/// rest) cannot reach it.
final class CredentialFieldsParserTests: XCTestCase {

    private func parse(
        host: String = "host.example.com",
        username: String = "u",
        password: String = "p",
        scheme: TransportScheme = .https
    ) throws -> Account {
        try CredentialFieldsParser.parse(host: host, username: username, password: password, scheme: scheme)
    }

    // MARK: - Host shapes

    func testBareHostTakesTheSelectedScheme() throws {
        XCTAssertEqual(try parse().host.absoluteString, "https://host.example.com")
        XCTAssertEqual(try parse(scheme: .http).host.absoluteString, "http://host.example.com")
    }

    func testHostWithPortKeepsThePort() throws {
        XCTAssertEqual(try parse(host: "host.example.com:8080").host.absoluteString, "https://host.example.com:8080")
    }

    func testSurroundingWhitespaceIsIgnored() throws {
        XCTAssertEqual(try parse(host: "  host.example.com:8080  ").host.absoluteString, "https://host.example.com:8080")
    }

    func testATypedSchemeIsAcceptedWhenItMatchesTheSelection() throws {
        XCTAssertEqual(try parse(host: "https://host.example.com").host.absoluteString, "https://host.example.com")
        XCTAssertEqual(try parse(host: "HTTP://host.example.com", scheme: .http).host.absoluteString, "http://host.example.com")
    }

    /// A pasted playlist URL should still land somewhere useful rather than
    /// corrupting every API URL built from this host later.
    func testAnythingPastTheAuthorityIsDropped() throws {
        let account = try parse(host: "host.example.com:8080/get.php?username=x&password=y")
        XCTAssertEqual(account.host.absoluteString, "https://host.example.com:8080")
        XCTAssertEqual(account.username, "u", "credentials come from the fields, never from the pasted tail")
        XCTAssertEqual(account.password, "p")
    }

    // MARK: - Rejections

    func testEmptyHostIsRejected() {
        XCTAssertThrowsError(try parse(host: "   ")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .missingHost)
        }
    }

    /// The selector is the authority; a contradiction is reported instead of
    /// one side silently winning.
    func testASchemeContradictingTheSelectionIsRejected() {
        XCTAssertThrowsError(try parse(host: "http://host.example.com", scheme: .https)) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .schemeMismatch(typed: "http", selected: "https"))
        }
    }

    func testANonWebSchemeIsRejected() {
        XCTAssertThrowsError(try parse(host: "rtmp://host.example.com")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .unsupportedScheme("rtmp"))
        }
    }

    func testUnparseableHostIsRejected() {
        // A scheme and nothing else: the field was not left blank, so
        // "invalid" describes it and "missing" would mislead.
        XCTAssertThrowsError(try parse(host: "https://")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .invalidHost)
        }
        XCTAssertThrowsError(try parse(host: "/only/a/path")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .invalidHost)
        }
    }

    func testMissingUsernameOrPasswordIsRejected() {
        XCTAssertThrowsError(try parse(username: "  ")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .missingUsername)
        }
        XCTAssertThrowsError(try parse(password: "")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .missingPassword)
        }
    }

    /// Credentials are opaque. A password whose surrounding spaces are real
    /// must survive: trimming would change it silently and leave the account
    /// unable to authenticate, with nothing on screen to explain why. The
    /// pasted-URL path preserves the decoded value the same way.
    func testCredentialsArePreservedVerbatim() throws {
        let account = try parse(username: "  user ", password: "  pass  ")
        XCTAssertEqual(account.username, "  user ")
        XCTAssertEqual(account.password, "  pass  ")
    }

    /// Whitespace still decides emptiness — a field holding only spaces was
    /// not filled in, whatever it contains.
    func testWhitespaceOnlyCredentialsAreStillRejected() {
        XCTAssertThrowsError(try parse(username: " \n ")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .missingUsername)
        }
        XCTAssertThrowsError(try parse(password: "   ")) { error in
            XCTAssertEqual(error as? CredentialFieldsError, .missingPassword)
        }
    }

    // MARK: - The URL the account goes on to build

    /// Live playback still has to come out in the `.m3u8` form, whichever way
    /// the account was entered.
    func testAccountFromFieldsBuildsTheUsualLiveURL() throws {
        let account = try parse(host: "host.example.com:8080", username: "u", password: "p", scheme: .http)
        let url = try XtreamClient(account: account, requestTimeout: 5).playbackURL(for: StreamID(42))
        XCTAssertEqual(url.absoluteString, "http://host.example.com:8080/live/u/p/42.m3u8")
    }
}
