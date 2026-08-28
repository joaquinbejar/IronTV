import XCTest
@testable import IronTV

/// The playlist-backed catalog. Everything here is the pure build step —
/// entries in, `Category`/`LiveStream` out — so no network is involved.
final class M3UCatalogClientTests: XCTestCase {

    private func entry(_ name: String, _ url: String, group: String? = nil, tvgID: String? = nil) -> M3UEntry {
        M3UEntry(name: name, url: URL(string: url)!, logoURL: nil, tvgID: tvgID, group: group)
    }

    // MARK: - Catalog shape

    func testGroupsBecomeCategoriesInFirstSeenOrder() {
        let built = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "Sports"),
            entry("C", "http://h/3.m3u8", group: "News"),
        ])
        XCTAssertEqual(built.categories.map(\.name), ["News", "Sports"])
        XCTAssertEqual(built.streams.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(built.streams[0].categoryID, built.streams[2].categoryID)
    }

    func testUngroupedEntriesLandInTheirOwnCategory() {
        let built = M3UCatalogClient.build(from: [entry("Lonely", "http://h/1.m3u8")])
        XCTAssertEqual(built.categories.count, 1)
        XCTAssertEqual(built.streams.first?.categoryID, built.categories.first?.id)
    }

    /// `tvg-id` is exactly what the Xtream path puts in `epgChannelID`, so a
    /// playlist account loses nothing here.
    func testTVGIdentifierBecomesTheEPGChannelIdentifier() {
        let built = M3UCatalogClient.build(from: [entry("A", "http://h/1.m3u8", tvgID: "bbc.one")])
        XCTAssertEqual(built.streams.first?.epgChannelID, "bbc.one")
    }

    /// The planner applies its same-host trust policy to `directSourceURL`;
    /// putting the entry URL there is what makes playback work without the
    /// client synthesising Xtream-shaped URLs.
    func testEntryURLIsCarriedAsTheDirectSource() {
        let built = M3UCatalogClient.build(from: [entry("A", "http://h/1.m3u8")])
        XCTAssertEqual(built.streams.first?.directSourceURL?.absoluteString, "http://h/1.m3u8")
        XCTAssertEqual(built.urlsByStream[built.streams[0].id]?.absoluteString, "http://h/1.m3u8")
    }

    // MARK: - Identifier stability

    /// Favorites and the last-watched channel are stored by id, so an id that
    /// moved when the provider inserted a channel would silently repoint them.
    func testIdentifiersDependOnTheEntryNotItsPosition() {
        let first = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "News"),
        ])
        let afterInsertion = M3UCatalogClient.build(from: [
            entry("New", "http://h/0.m3u8", group: "News"),
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("B", "http://h/2.m3u8", group: "News"),
        ])
        XCTAssertEqual(first.streams[0].id, afterInsertion.streams[1].id)
        XCTAssertEqual(first.streams[1].id, afterInsertion.streams[2].id)
        XCTAssertEqual(first.categories[0].id, afterInsertion.categories[0].id)
    }

    /// Swift's `hashValue` is seeded per process; these ids are persisted, so
    /// they must not be.
    func testIdentifiersAreStableAcrossCalls() {
        XCTAssertEqual(
            M3UCatalogClient.stableID(for: "http://h/1.m3u8"),
            M3UCatalogClient.stableID(for: "http://h/1.m3u8")
        )
        XCTAssertNotEqual(
            M3UCatalogClient.stableID(for: "http://h/1.m3u8"),
            M3UCatalogClient.stableID(for: "http://h/2.m3u8")
        )
    }

    func testIdentifiersAreNonNegative() {
        for text in ["", "http://h/1.m3u8", "ñ é 中文", String(repeating: "x", count: 4096)] {
            XCTAssertGreaterThanOrEqual(M3UCatalogClient.stableID(for: text), 0, "input: \(text.prefix(20))")
        }
    }

    /// Two entries are two channels even if their ids would have collided.
    func testDuplicateEntryURLsBothSurvive() {
        let built = M3UCatalogClient.build(from: [
            entry("A", "http://h/1.m3u8", group: "News"),
            entry("A again", "http://h/1.m3u8", group: "News"),
        ])
        XCTAssertEqual(built.streams.count, 2)
        XCTAssertNotEqual(built.streams[0].id, built.streams[1].id)
    }
}
