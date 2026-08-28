import XCTest
@testable import IronTV

/// Playlist parsing, against fixtures rather than the network. The posture
/// mirrors the DTO tests: providers are inconsistent, and one malformed entry
/// must never cost the rest of the catalog.
final class M3UPlaylistParserTests: XCTestCase {

    private func entries(_ fixture: String) throws -> [M3UEntry] {
        try M3UPlaylistParser.parse(fixtureText(fixture, extension: "m3u"))
    }

    // MARK: - Well-formed

    func testReadsNameURLAttributesAndGroup() throws {
        let entries = try entries("playlist_basic")
        XCTAssertEqual(entries.count, 4)

        let first = entries[0]
        XCTAssertEqual(first.name, "UK News HD")
        XCTAssertEqual(first.url.absoluteString, "http://host.example.com/live/u/p/101.m3u8")
        XCTAssertEqual(first.tvgID, "news.uk")
        XCTAssertEqual(first.logoURL?.absoluteString, "http://host.example.com/logos/news.png")
        XCTAssertEqual(first.group, "News")
    }

    /// Channel names contain commas. The split is on the last comma outside a
    /// quoted attribute value, so the name survives intact.
    func testNameKeepsItsOwnCommas() throws {
        let entries = try entries("playlist_basic")
        XCTAssertEqual(entries[1].name, "France 24, Live")
        XCTAssertEqual(entries[1].group, "News")
    }

    func testAttributeOrderDoesNotMatter() throws {
        let entries = try entries("playlist_basic")
        XCTAssertEqual(entries[2].tvgID, "sports.1")
        XCTAssertEqual(entries[2].logoURL?.absoluteString, "http://host.example.com/logos/s.png")
        XCTAssertEqual(entries[2].group, "Sports")
    }

    func testAnEntryWithNoGroupIsKept() throws {
        let entries = try entries("playlist_basic")
        XCTAssertEqual(entries[3].name, "Ungrouped Channel")
        XCTAssertNil(entries[3].group, "ungrouped is a real state, not a parse failure")
    }

    func testCRLFLineEndings() throws {
        let entries = try entries("playlist_crlf")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "CRLF Channel")
        XCTAssertEqual(entries[0].url.absoluteString, "http://host.example.com/live/u/p/201.m3u8")
    }

    // MARK: - Forgiveness

    func testMessyPlaylistKeepsEveryUsableEntry() throws {
        let entries = try entries("playlist_messy")
        // Bare entry, empty attributes, and the tvg-name fallback. The entry
        // with an unusable URL is the only one dropped.
        XCTAssertEqual(entries.map(\.name), ["Bare Entry", "Empty Attributes", "From TVG Name"])
    }

    func testEmptyAttributeValuesBecomeNilNotEmptyStrings() throws {
        let entries = try entries("playlist_messy")
        let emptyAttributes = try XCTUnwrap(entries.first { $0.name == "Empty Attributes" })
        XCTAssertNil(emptyAttributes.tvgID)
        XCTAssertNil(emptyAttributes.group)
    }

    func testUnknownDirectivesAndBlankLinesDoNotBreakTheFollowingEntry() throws {
        let entries = try entries("playlist_messy")
        XCTAssertTrue(entries.contains { $0.name == "Empty Attributes" },
                      "#EXTVLCOPT and a blank line preceded it")
    }

    func testASkippedEntryIsCounted() throws {
        var parser = M3UPlaylistParser()
        try fixtureText("playlist_messy", extension: "m3u").enumerateLines { line, _ in
            parser.consume(line: line)
        }
        _ = try parser.finish()
        XCTAssertEqual(parser.skippedEntryCount, 1, "the unusable URL is reported, not hidden")
    }

    // MARK: - Rejections

    /// A truncated download must not look like a provider with few channels.
    func testTruncatedPlaylistWithNoCompleteEntryThrows() throws {
        XCTAssertThrowsError(try entries("playlist_truncated")) { error in
            XCTAssertEqual(error as? M3UPlaylistError, .truncated)
        }
    }

    /// The dangerous truncation: a download that died a third of the way in
    /// still has valid entries, so without this it is served as a complete
    /// catalog that is simply smaller than the provider's.
    func testTruncationAfterValidEntriesIsStillRejected() throws {
        XCTAssertThrowsError(try entries("playlist_truncated_after_entries")) { error in
            XCTAssertEqual(error as? M3UPlaylistError, .truncated)
        }
    }

    func testSomethingThatIsNotAPlaylistThrows() {
        XCTAssertThrowsError(try M3UPlaylistParser.parse("<html><body>404</body></html>")) { error in
            XCTAssertEqual(error as? M3UPlaylistError, .notAPlaylist)
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try M3UPlaylistParser.parse("")) { error in
            XCTAssertEqual(error as? M3UPlaylistError, .notAPlaylist)
        }
    }

    /// A playlist with entries but no header is still a playlist — some
    /// providers omit it.
    func testMissingHeaderIsToleratedWhenEntriesParse() throws {
        let parsed = try M3UPlaylistParser.parse("""
        #EXTINF:-1,No Header
        http://host.example.com/live/u/p/1.m3u8
        """)
        XCTAssertEqual(parsed.map(\.name), ["No Header"])
    }
}
