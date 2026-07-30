import XCTest
@testable import IronTV

final class XtreamClientURLTests: XCTestCase {

    private let account = Account(
        host: URL(string: "http://host.example.com:8080")!,
        username: "user1",
        password: "pass1"
    )

    private var client: XtreamClient { XtreamClient(account: account) }

    // MARK: - player_api.php

    func testPlayerAPIURLWithoutAction() throws {
        let url = try client.playerAPIURL(action: nil)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "host.example.com")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/player_api.php")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "username", value: "user1"),
            URLQueryItem(name: "password", value: "pass1"),
        ])
    }

    func testPlayerAPIURLWithAction() throws {
        let url = try client.playerAPIURL(action: "get_live_categories")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "action", value: "get_live_categories")) ?? false)
    }

    func testPlayerAPIURLWithCategoryFilter() throws {
        let url = try client.playerAPIURL(action: "get_live_streams", categoryID: CategoryID(12))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "action", value: "get_live_streams")) ?? false)
        XCTAssertTrue(components.queryItems?.contains(URLQueryItem(name: "category_id", value: "12")) ?? false)
    }

    func testPlayerAPIURLPercentEncodesCredentials() throws {
        let odd = Account(
            host: URL(string: "http://host.example.com")!,
            username: "us er&x",
            password: "p@ss=1"
        )
        let url = try XtreamClient(account: odd).playerAPIURL(action: nil)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        // Round-trip through URLComponents must recover the raw values.
        XCTAssertEqual(components.queryItems?.first { $0.name == "username" }?.value, "us er&x")
        XCTAssertEqual(components.queryItems?.first { $0.name == "password" }?.value, "p@ss=1")
    }

    // MARK: - Playback URL

    func testPlaybackURL() throws {
        let url = try client.playbackURL(for: StreamID(1001))
        XCTAssertEqual(url.absoluteString, "http://host.example.com:8080/live/user1/pass1/1001.m3u8")
    }

    func testPlaybackURLWithoutExplicitPort() throws {
        let noPort = Account(host: URL(string: "https://host.example.com")!, username: "u", password: "p")
        let url = try XtreamClient(account: noPort).playbackURL(for: StreamID(7))
        XCTAssertEqual(url.absoluteString, "https://host.example.com/live/u/p/7.m3u8")
    }

    // MARK: - Credential redaction

    func testRedactsQueryCredentials() throws {
        let url = try client.playerAPIURL(action: "get_live_streams", categoryID: CategoryID(3))
        let redacted = CredentialRedactor.redact(url)

        XCTAssertFalse(redacted.contains("user1"))
        XCTAssertFalse(redacted.contains("pass1"))
        XCTAssertTrue(redacted.contains("username=REDACTED"))
        XCTAssertTrue(redacted.contains("password=REDACTED"))
        XCTAssertTrue(redacted.contains("action=get_live_streams"), "non-credential params must survive")
        XCTAssertTrue(redacted.contains("category_id=3"), "non-credential params must survive")
    }

    func testRedactsPathCredentialsInPlaybackURL() throws {
        let url = try client.playbackURL(for: StreamID(1001))
        let redacted = CredentialRedactor.redact(url)

        XCTAssertEqual(redacted, "http://host.example.com:8080/live/REDACTED/REDACTED/1001.m3u8")
    }

    func testRedactionLeavesCredentialFreeURLsAlone() {
        let url = URL(string: "http://cdn.example.com/logos/news1.png")!
        XCTAssertEqual(CredentialRedactor.redact(url), url.absoluteString)
    }

    // MARK: - Hostile credentials

    /// Provider-issued credentials seen in the wild: slashes, percents, spaces,
    /// Unicode, URL metacharacters. Each pair must survive path encoding
    /// byte-exactly and never appear in a redacted URL.
    private let hostileCredentials: [(username: String, password: String)] = [
        ("us/er", "topsecret"),
        ("user", "top/secret/x"),
        ("100%legit", "50%off%2F"),
        ("us er", "top secret"),
        ("üser日本", "pässwörd中文"),
        ("what?user", "why?pass"),
        ("hash#user", "pass#tag"),
        ("user@host", "p@ss@"),
        ("a&b+c", "d&e+f"),
    ]

    func testPlaybackURLEncodesEachCredentialAsOneSegment() throws {
        for (username, password) in hostileCredentials {
            let account = Account(host: URL(string: "http://host.example.com:8080")!, username: username, password: password)
            let url = try XtreamClient(account: account).playbackURL(for: StreamID(1001))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            let encoded = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
            XCTAssertEqual(encoded.count, 4, "credential '\(username)'/'\(password)' must stay in exactly one segment each")
            XCTAssertEqual(encoded.first.map(String.init), "live")
            XCTAssertEqual(encoded.last.map(String.init), "1001.m3u8")
            // Byte preservation: decoding the segments recovers the raw values.
            XCTAssertEqual(String(encoded[1]).removingPercentEncoding, username)
            XCTAssertEqual(String(encoded[2]).removingPercentEncoding, password)
        }
    }

    func testPlaybackURLPreservesProviderBytesFromM3UQuery() throws {
        let account = try M3UURLParser.parse(
            "http://host.example.com:8080/get.php?username=us%2Fer1&password=top%20secret%25&type=m3u_plus"
        )
        XCTAssertEqual(account.username, "us/er1")
        XCTAssertEqual(account.password, "top secret%")

        let url = try XtreamClient(account: account).playbackURL(for: StreamID(7))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encoded = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)

        XCTAssertEqual(String(encoded[1]).removingPercentEncoding, "us/er1")
        XCTAssertEqual(String(encoded[2]).removingPercentEncoding, "top secret%")
    }

    func testRedactionNeverLeaksHostileCredentials() throws {
        for (username, password) in hostileCredentials {
            let account = Account(host: URL(string: "http://host.example.com:8080")!, username: username, password: password)
            let url = try XtreamClient(account: account).playbackURL(for: StreamID(1001))
            let redacted = CredentialRedactor.redact(url)

            XCTAssertFalse(redacted.contains(username), "raw username '\(username)' leaked into \(redacted)")
            XCTAssertFalse(redacted.contains(password), "raw password leaked for user '\(username)'")
            XCTAssertEqual(redacted, "http://host.example.com:8080/live/REDACTED/REDACTED/1001.m3u8")
        }
    }

    func testRedactionMasksLegacyURLsWithDecodedSlashCredentials() throws {
        // Shape the previous URL builder produced for username "us/er": the
        // password landed beyond segment 2 and used to survive redaction.
        let url = try XCTUnwrap(URL(string: "http://host.example.com/live/us/er/topsecret/1001.m3u8"))
        let redacted = CredentialRedactor.redact(url)

        XCTAssertFalse(redacted.contains("topsecret"))
        XCTAssertEqual(redacted, "http://host.example.com/live/REDACTED/REDACTED/1001.m3u8")
    }

    func testPlaybackURLRejectsEmptyCredentials() {
        for (username, password) in [("", "pass"), ("user", ""), ("", "")] {
            let account = Account(host: URL(string: "http://host.example.com")!, username: username, password: password)
            XCTAssertThrowsError(try XtreamClient(account: account).playbackURL(for: StreamID(1))) { error in
                guard case XtreamAPIError.invalidURL = error else {
                    return XCTFail("expected invalidURL, got \(error)")
                }
            }
        }
    }
}
