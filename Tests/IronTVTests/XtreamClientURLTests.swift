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
}
