import XCTest
@testable import IronTV

final class SameOriginRedirectPolicyTests: XCTestCase {

    private func url(_ string: String) -> URL? { URL(string: string) }

    func testAllowsRedirectsWithinTheSameOrigin() {
        XCTAssertTrue(SameOriginRedirectPolicy.allowsRedirect(
            from: url("https://host.example.com:8443/player_api.php?username=u&password=p"),
            to: url("https://host.example.com:8443/portal/player_api.php")
        ))
        // Default ports match their explicit forms.
        XCTAssertTrue(SameOriginRedirectPolicy.allowsRedirect(
            from: url("https://host.example.com/player_api.php"),
            to: url("https://host.example.com:443/player_api.php")
        ))
        XCTAssertTrue(SameOriginRedirectPolicy.allowsRedirect(
            from: url("http://host.example.com:80/a"),
            to: url("http://host.example.com/b")
        ))
    }

    func testRefusesSchemeDowngrades() {
        // The finding that motivated the policy: an HTTPS panel redirecting
        // the credential-bearing query to plain HTTP.
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(
            from: url("https://host.example.com:8443/player_api.php?username=u&password=p"),
            to: url("http://host.example.com:8443/player_api.php?username=u&password=p")
        ))
    }

    func testRefusesHostAndPortChanges() {
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(
            from: url("https://host.example.com/player_api.php"),
            to: url("https://other.example.com/player_api.php")
        ))
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(
            from: url("http://host.example.com:8080/player_api.php"),
            to: url("http://host.example.com:8081/player_api.php")
        ))
    }

    func testRefusesWhenEitherURLIsMissingOrHostless() {
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(from: nil, to: url("https://host.example.com")))
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(from: url("https://host.example.com"), to: nil))
        XCTAssertFalse(SameOriginRedirectPolicy.allowsRedirect(
            from: url("https://host.example.com/a"),
            to: URL(string: "about:blank")
        ))
    }
}
