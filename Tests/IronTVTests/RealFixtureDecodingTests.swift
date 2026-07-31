import XCTest
@testable import IronTV

/// Decodes responses recorded from a real Xtream panel (credentials redacted).
/// Guards against panel quirks the synthetic fixtures don't cover.
final class RealFixtureDecodingTests: XCTestCase {

    func testRealAccountInfoDecodesAndMaps() throws {
        let dto = try decodeFixture(AccountInfoDTO.self, from: "account_info_real")

        let userInfo = try XCTUnwrap(dto.userInfo)
        XCTAssertEqual(userInfo.auth, 1)
        XCTAssertEqual(userInfo.status, "Active")

        let status = userInfo.toDomain()
        XCTAssertTrue(status.authenticated)
        XCTAssertNotNil(status.expiryDate)

        // This panel reports "0" — TLS off. That must read as no advertised
        // endpoint, never as an invitation to probe port 0.
        XCTAssertNil(dto.toAccountStatus().advertisedHTTPSPort)
    }

    func testRealLiveCategoriesDecodeAndMap() throws {
        let dtos = try decodeFixture([LiveCategoryDTO].self, from: "live_categories_real")
        XCTAssertFalse(dtos.isEmpty)

        let categories = dtos.compactMap { $0.toDomain() }
        XCTAssertEqual(categories.count, dtos.count, "every real category row must map cleanly")
    }

    func testRealLiveStreamsDecodeAndMap() throws {
        let dtos = try decodeFixture([LiveStreamDTO].self, from: "live_streams_real")
        XCTAssertFalse(dtos.isEmpty)

        let streams = dtos.compactMap { $0.toDomain() }
        XCTAssertEqual(streams.count, dtos.count, "every real stream row must map cleanly")
        XCTAssertTrue(streams.allSatisfy { $0.id.rawValue > 0 })
    }
}
