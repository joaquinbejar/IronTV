import XCTest
@testable import IronTV

final class M3UURLParserTests: XCTestCase {

    // MARK: - Happy paths

    func testParsesCanonicalProviderURL() throws {
        let account = try M3UURLParser.parse(
            "http://host.example.com:8080/get.php?username=user1&password=pass1&type=m3u_plus"
        )

        XCTAssertEqual(account.host.absoluteString, "http://host.example.com:8080")
        XCTAssertEqual(account.username, "user1")
        XCTAssertEqual(account.password, "pass1")
    }

    func testParsesHTTPSWithoutPort() throws {
        let account = try M3UURLParser.parse("https://panel.example.com/get.php?username=u&password=p")

        XCTAssertEqual(account.host.absoluteString, "https://panel.example.com")
        XCTAssertEqual(account.username, "u")
        XCTAssertEqual(account.password, "p")
    }

    func testParsesQueryParamsInAnyOrder() throws {
        let account = try M3UURLParser.parse(
            "http://h.example.com:80/get.php?type=m3u_plus&password=p1&output=ts&username=u1"
        )

        XCTAssertEqual(account.username, "u1")
        XCTAssertEqual(account.password, "p1")
    }

    func testToleratesSurroundingWhitespace() throws {
        let account = try M3UURLParser.parse(
            "  \n http://host.example.com:8080/get.php?username=u&password=p&type=m3u_plus \t\n"
        )

        XCTAssertEqual(account.host.absoluteString, "http://host.example.com:8080")
    }

    func testToleratesUppercaseSchemeAndParamNames() throws {
        let account = try M3UURLParser.parse("HTTP://host.example.com/get.php?USERNAME=u&Password=p")

        XCTAssertEqual(account.host.absoluteString, "http://host.example.com")
        XCTAssertEqual(account.username, "u")
        XCTAssertEqual(account.password, "p")
    }

    func testDecodesPercentEncodedCredentials() throws {
        let account = try M3UURLParser.parse("http://h.example.com/get.php?username=us%20er&password=p%26q")

        XCTAssertEqual(account.username, "us er")
        XCTAssertEqual(account.password, "p&q")
    }

    // MARK: - Failure modes

    func testRejectsNonHTTPScheme() {
        XCTAssertThrowsError(try M3UURLParser.parse("ftp://host.example.com/get.php?username=u&password=p")) {
            XCTAssertEqual($0 as? M3UURLParseError, .unsupportedScheme("ftp"))
        }
    }

    func testRejectsMissingUsername() {
        XCTAssertThrowsError(try M3UURLParser.parse("http://host.example.com/get.php?password=p")) {
            XCTAssertEqual($0 as? M3UURLParseError, .missingUsername)
        }
    }

    func testRejectsEmptyUsername() {
        XCTAssertThrowsError(try M3UURLParser.parse("http://host.example.com/get.php?username=&password=p")) {
            XCTAssertEqual($0 as? M3UURLParseError, .missingUsername)
        }
    }

    func testRejectsMissingPassword() {
        XCTAssertThrowsError(try M3UURLParser.parse("http://host.example.com/get.php?username=u&type=m3u")) {
            XCTAssertEqual($0 as? M3UURLParseError, .missingPassword)
        }
    }

    func testMalformedInputTable() {
        let cases: [(input: String, expected: M3UURLParseError)] = [
            ("", .notAURL),
            ("   \n\t ", .notAURL),
            ("definitely not a url", .notAURL),
            ("hello", .notAURL),                          // no scheme
            ("/get.php?username=u&password=p", .notAURL), // no scheme, no host
            ("http://", .notAURL),                        // no host
            ("http:///get.php?username=u&password=p", .notAURL),
            ("rtmp://host.example.com/live?username=u&password=p", .unsupportedScheme("rtmp")),
            ("file:///etc/passwd", .unsupportedScheme("file")),
            ("http://host.example.com/get.php", .missingUsername),
            ("http://host.example.com/get.php?username=u", .missingPassword),
            ("http://host.example.com/get.php?username=u&password=", .missingPassword),
        ]

        for (input, expected) in cases {
            XCTAssertThrowsError(try M3UURLParser.parse(input), "expected error for \(input.debugDescription)") {
                XCTAssertEqual($0 as? M3UURLParseError, expected, "for \(input.debugDescription)")
            }
        }
    }
}
