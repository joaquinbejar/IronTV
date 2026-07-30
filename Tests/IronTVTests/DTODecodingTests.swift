import XCTest
@testable import IronTV

/// Every numeric field must decode identically whether the panel sends it as
/// Int or String — each test runs against both fixture variants.
final class DTODecodingTests: XCTestCase {

    // MARK: - Account info

    func testAccountInfoDecodesFromBothVariants() throws {
        for fixture in ["account_info_int", "account_info_string"] {
            let dto = try decodeFixture(AccountInfoDTO.self, from: fixture)

            let userInfo = try XCTUnwrap(dto.userInfo, "user_info missing in \(fixture)")
            XCTAssertEqual(userInfo.username, "fixtureuser", "in \(fixture)")
            XCTAssertEqual(userInfo.auth, 1, "in \(fixture)")
            XCTAssertEqual(userInfo.status, "Active", "in \(fixture)")
            XCTAssertEqual(userInfo.expDate, 1_767_225_600, "in \(fixture)")
            XCTAssertEqual(userInfo.activeCons, 0, "in \(fixture)")
            XCTAssertEqual(userInfo.maxConnections, 2, "in \(fixture)")
            XCTAssertEqual(userInfo.allowedOutputFormats, ["m3u8", "ts"], "in \(fixture)")

            let serverInfo = try XCTUnwrap(dto.serverInfo, "server_info missing in \(fixture)")
            XCTAssertEqual(serverInfo.port, 8080, "in \(fixture)")
            XCTAssertEqual(serverInfo.httpsPort, 8443, "in \(fixture)")
            XCTAssertEqual(serverInfo.rtmpPort, 25462, "in \(fixture)")
            XCTAssertEqual(serverInfo.timestampNow, 1_750_000_000, "in \(fixture)")
        }
    }

    // MARK: - Live categories

    func testLiveCategoriesDecodeFromBothVariants() throws {
        for fixture in ["live_categories_int", "live_categories_string"] {
            let dtos = try decodeFixture([LiveCategoryDTO].self, from: fixture)

            XCTAssertEqual(dtos.count, 3, "in \(fixture)")
            XCTAssertEqual(dtos[0].categoryId, 7, "in \(fixture)")
            XCTAssertEqual(dtos[0].categoryName, "News", "in \(fixture)")
            XCTAssertEqual(dtos[0].parentId, 0, "in \(fixture)")
            XCTAssertEqual(dtos[2].parentId, 12, "in \(fixture)")
        }
    }

    // MARK: - Live streams

    func testLiveStreamsDecodeFromBothVariants() throws {
        for fixture in ["live_streams_int", "live_streams_string"] {
            let dtos = try decodeFixture([LiveStreamDTO].self, from: fixture)

            XCTAssertEqual(dtos.count, 2, "in \(fixture)")
            XCTAssertEqual(dtos[0].streamId, 1001, "in \(fixture)")
            XCTAssertEqual(dtos[0].name, "News Channel One", "in \(fixture)")
            XCTAssertEqual(dtos[0].categoryId, 7, "in \(fixture)")
            XCTAssertEqual(dtos[0].epgChannelId, "news1.example", "in \(fixture)")
            XCTAssertEqual(dtos[0].tvArchive, 0, "in \(fixture)")
            XCTAssertEqual(dtos[1].streamId, 1002, "in \(fixture)")
            XCTAssertNil(dtos[1].epgChannelId, "in \(fixture)")
            XCTAssertEqual(dtos[1].tvArchiveDuration, 24, "in \(fixture)")
        }
    }

    // MARK: - Flexible decoding edge cases

    private struct Probe: Decodable {
        @FlexibleInt var value: Int?
        @FlexibleString var text: String?
    }

    func testFlexibleFieldsTolerateMissingNullAndGarbage() throws {
        let cases: [(json: String, value: Int?, text: String?)] = [
            (#"{"value": 5, "text": "a"}"#, 5, "a"),
            (#"{"value": "5", "text": 7}"#, 5, "7"),
            (#"{"value": " 5 ", "text": null}"#, 5, nil),
            (#"{"value": "5.0", "text": 1.5}"#, 5, "1.5"),
            (#"{"value": null}"#, nil, nil),
            (#"{}"#, nil, nil),
            (#"{"value": "abc", "text": true}"#, nil, "true"),
            (#"{"value": [1], "text": {}}"#, nil, nil),
        ]
        for (json, value, text) in cases {
            let probe = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
            XCTAssertEqual(probe.value, value, "for \(json)")
            XCTAssertEqual(probe.text, text, "for \(json)")
        }
    }

    /// A panel can put anything in a numeric field. Every one of these used to
    /// reach a trapping `Int(Double)` conversion and terminate the process.
    func testFlexibleIntRejectsUnrepresentableValuesInsteadOfTrapping() throws {
        let intMax = String(Int.max)
        let intMin = String(Int.min)
        let cases: [(json: String, value: Int?)] = [
            // Boundaries must survive exactly, as number and as string.
            (#"{"value": \#(intMax)}"#, Int.max),
            (#"{"value": "\#(intMax)"}"#, Int.max),
            (#"{"value": \#(intMin)}"#, Int.min),
            (#"{"value": "\#(intMin)"}"#, Int.min),
            // Just past the top of the range. The bottom has no testable
            // neighbour: Int.min is -2^63, and the next integer below it rounds
            // back onto -2^63 in Double, so use a clear overshoot instead.
            (#"{"value": 9223372036854775808}"#, nil),
            (#"{"value": "9223372036854775808"}"#, nil),
            (#"{"value": -1e19}"#, nil),
            (#"{"value": "-1e19"}"#, nil),
            // Large exponents — the crash this test exists for.
            (#"{"value": 1e100}"#, nil),
            (#"{"value": "1e100"}"#, nil),
            (#"{"value": -1e100}"#, nil),
            // Non-finite spellings, reachable only through the string path.
            (#"{"value": "nan"}"#, nil),
            (#"{"value": "NaN"}"#, nil),
            (#"{"value": "inf"}"#, nil),
            (#"{"value": "infinity"}"#, nil),
            (#"{"value": "-infinity"}"#, nil),
            // Fractional values truncate toward zero; a magnitude below one
            // lands on 0, not nil.
            (#"{"value": 5.7}"#, 5),
            (#"{"value": "5.7"}"#, 5),
            (#"{"value": -5.7}"#, -5),
            (#"{"value": "-5.7"}"#, -5),
            (#"{"value": 1e-5}"#, 0),
            (#"{"value": "1e-5"}"#, 0),
            (#"{"value": "-0.0"}"#, 0),
        ]
        for (json, value) in cases {
            let probe = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
            XCTAssertEqual(probe.value, value, "for \(json)")
        }
    }

    /// The helper both decode paths share, exercised directly.
    func testPanelDoubleConversionRejectsNonFiniteAndOutOfRange() {
        XCTAssertEqual(FlexibleInt.int(fromPanelDouble: 5.0), 5)
        XCTAssertEqual(FlexibleInt.int(fromPanelDouble: -5.9), -5)
        XCTAssertEqual(FlexibleInt.int(fromPanelDouble: 0.4), 0)
        XCTAssertEqual(FlexibleInt.int(fromPanelDouble: -9_223_372_036_854_775_808.0), Int.min)
        XCTAssertNil(FlexibleInt.int(fromPanelDouble: .nan))
        XCTAssertNil(FlexibleInt.int(fromPanelDouble: .infinity))
        XCTAssertNil(FlexibleInt.int(fromPanelDouble: -.infinity))
        XCTAssertNil(FlexibleInt.int(fromPanelDouble: 9_223_372_036_854_775_808.0))
        XCTAssertNil(FlexibleInt.int(fromPanelDouble: 1e100))
    }
}
