import XCTest
@testable import IronTV

final class PlaybackTransportPolicyTests: XCTestCase {

    private let httpsOrigin = URL(string: "https://host.example.com:8443/live/u/p/1.m3u8")!
    private let httpOrigin = URL(string: "http://host.example.com:8080/live/u/p/1.m3u8")!

    private func verdict(_ uri: String, origin: URL) -> PlaybackTransportVerdict {
        PlaybackTransportPolicy.verdict(observedURI: uri, plannedOrigin: origin)
    }

    func testSameOriginRequestsAreAcceptable() {
        XCTAssertEqual(verdict("https://host.example.com:8443/segments/00042.ts", origin: httpsOrigin), .acceptable)
        XCTAssertEqual(verdict("http://host.example.com:8080/other/path.m3u8", origin: httpOrigin), .acceptable)
        // Default-port equivalence rides the shared same-origin rule.
        XCTAssertEqual(verdict("https://host.example.com:443/x.ts", origin: URL(string: "https://host.example.com/1.m3u8")!), .acceptable)
    }

    /// The reverse of the downgrade: moving to https on the same host is a
    /// hardening upgrade and must not stop playback.
    func testSameHostSchemeUpgradeIsAcceptable() {
        XCTAssertEqual(verdict("https://host.example.com/segments/1.ts", origin: httpOrigin), .acceptable)
        XCTAssertEqual(verdict("https://host.example.com:8443/1.ts", origin: httpOrigin), .acceptable)
        XCTAssertEqual(verdict("https://cdn.example.org/1.ts", origin: httpOrigin), .crossOrigin, "an upgrade to another host is still cross-origin")
    }

    func testHTTPSDowngradeIsDetected() {
        XCTAssertEqual(verdict("http://host.example.com:8443/segments/1.ts", origin: httpsOrigin), .downgraded)
    }

    func testCrossOriginMovesAreDetected() {
        XCTAssertEqual(verdict("http://evil.example.net/segments/1.ts", origin: httpOrigin), .crossOrigin)
        XCTAssertEqual(verdict("http://host.example.com:9999/1.ts", origin: httpOrigin), .crossOrigin)
        // https elsewhere is still not the planned origin.
        XCTAssertEqual(verdict("https://cdn.example.org/1.ts", origin: httpsOrigin), .crossOrigin)
    }

    func testRelativeAndGarbageURIsAreAcceptable() {
        XCTAssertEqual(verdict("segments/00042.ts", origin: httpOrigin), .acceptable)
        XCTAssertEqual(verdict("/absolute/path.ts", origin: httpOrigin), .acceptable)
        XCTAssertEqual(verdict("not a uri at all", origin: httpOrigin), .acceptable)
        XCTAssertEqual(verdict("", origin: httpOrigin), .acceptable)
    }

    /// The review's bypass: a scheme-relative URI resolves with the planned
    /// scheme onto a different host — it must be judged as the absolute URL
    /// it becomes, not skipped as "relative".
    func testSchemeRelativeURIsResolveBeforeJudging() {
        XCTAssertEqual(verdict("//evil.example.net/segments/1.ts", origin: httpOrigin), .crossOrigin)
        XCTAssertEqual(verdict("//host.example.com:8080/segments/1.ts", origin: httpOrigin), .acceptable)
        // https planned origin + scheme-relative to another host is judged on
        // the resolved https URL: still cross-origin.
        XCTAssertEqual(verdict("//cdn.example.org/x.ts", origin: httpsOrigin), .crossOrigin)
    }

    /// Absolute non-web or hostless URIs can never be the planned origin.
    func testAbsoluteNonWebURIsAreViolations() {
        XCTAssertEqual(verdict("file:///etc/passwd", origin: httpOrigin), .crossOrigin)
        XCTAssertEqual(verdict("data:text/plain;base64,QQ==", origin: httpOrigin), .crossOrigin)
        XCTAssertEqual(verdict("rtmp://host.example.com/live", origin: httpOrigin), .crossOrigin)
        XCTAssertEqual(verdict("http:///hostless/path", origin: httpOrigin), .crossOrigin)
    }

    func testFirstViolationScansTheWholeBatch() {
        let uris = [
            "segments/1.ts",
            "http://host.example.com:8080/2.ts",
            "http://evil.example.net/3.ts",
        ]
        XCTAssertEqual(PlaybackTransportPolicy.firstViolation(in: uris, plannedOrigin: httpOrigin), .crossOrigin)
        XCTAssertNil(PlaybackTransportPolicy.firstViolation(in: Array(uris.prefix(2)), plannedOrigin: httpOrigin))
    }
}
