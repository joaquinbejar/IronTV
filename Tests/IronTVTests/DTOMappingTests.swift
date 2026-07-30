import XCTest
@testable import IronTV

final class DTOMappingTests: XCTestCase {

    func testCategoryMapping() throws {
        let dtos = try decodeFixture([LiveCategoryDTO].self, from: "live_categories_string")
        let categories = dtos.compactMap { $0.toDomain() }

        XCTAssertEqual(categories.count, 3)
        XCTAssertEqual(categories[0], Category(id: CategoryID(7), name: "News"))
    }

    func testCategoryMappingDropsRowsWithoutIDOrName() throws {
        let json = #"[{"category_name": "Orphan"}, {"category_id": 5}, {"category_id": 6, "category_name": "OK"}]"#
        let dtos = try JSONDecoder().decode([LiveCategoryDTO].self, from: Data(json.utf8))
        let categories = dtos.compactMap { $0.toDomain() }

        XCTAssertEqual(categories, [Category(id: CategoryID(6), name: "OK")])
    }

    func testLiveStreamMapping() throws {
        let dtos = try decodeFixture([LiveStreamDTO].self, from: "live_streams_int")
        let streams = dtos.compactMap { $0.toDomain() }

        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(streams[0].id, StreamID(1001))
        XCTAssertEqual(streams[0].categoryID, CategoryID(7))
        XCTAssertEqual(streams[0].iconURL, URL(string: "http://cdn.example.com/logos/news1.png"))
        XCTAssertEqual(streams[0].epgChannelID, "news1.example")
        // Empty stream_icon must map to nil, not URL("").
        XCTAssertNil(streams[1].iconURL)
    }

    func testLiveStreamMappingUsesFallbackCategory() throws {
        let json = #"[{"stream_id": 42, "name": "No Category"}]"#
        let dtos = try JSONDecoder().decode([LiveStreamDTO].self, from: Data(json.utf8))

        XCTAssertNil(dtos[0].toDomain(), "no category_id and no fallback must drop the row")
        let stream = try XCTUnwrap(dtos[0].toDomain(fallbackCategoryID: CategoryID(9)))
        XCTAssertEqual(stream.categoryID, CategoryID(9))
    }

    func testUserInfoMapping() throws {
        let dto = try decodeFixture(AccountInfoDTO.self, from: "account_info_string")
        let status = try XCTUnwrap(dto.userInfo).toDomain()

        XCTAssertTrue(status.authenticated)
        XCTAssertEqual(status.status, "Active")
        XCTAssertEqual(status.expiryDate, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(status.maxConnections, 2)
    }

    func testUserInfoMappingUnauthenticated() throws {
        let json = #"{"user_info": {"auth": 0, "status": "Expired", "exp_date": null}}"#
        let dto = try JSONDecoder().decode(AccountInfoDTO.self, from: Data(json.utf8))
        let status = try XCTUnwrap(dto.userInfo).toDomain()

        XCTAssertFalse(status.authenticated)
        XCTAssertEqual(status.status, "Expired")
        XCTAssertNil(status.expiryDate)
    }

    func testUserInfoMappingExpirySentinelsMapToNoKnownExpiry() throws {
        let sentinels: [(label: String, json: String)] = [
            ("missing", #"{"user_info": {"auth": 1}}"#),
            ("null", #"{"user_info": {"auth": 1, "exp_date": null}}"#),
            ("zero Int", #"{"user_info": {"auth": 1, "exp_date": 0}}"#),
            ("zero String", #"{"user_info": {"auth": 1, "exp_date": "0"}}"#),
            ("negative", #"{"user_info": {"auth": 1, "exp_date": -1}}"#),
            ("implausibly small", #"{"user_info": {"auth": 1, "exp_date": 1}}"#),
            ("millisecond-scale", #"{"user_info": {"auth": 1, "exp_date": 1767225600000}}"#),
        ]
        for (label, json) in sentinels {
            let dto = try JSONDecoder().decode(AccountInfoDTO.self, from: Data(json.utf8))
            let status = try XCTUnwrap(dto.userInfo).toDomain()

            XCTAssertNil(status.expiryDate, "\(label) exp_date must map to no known expiry")
            XCTAssertTrue(status.authenticated, "\(label) exp_date must not affect authentication")
        }
    }

    func testUserInfoMappingKeepsPlausiblePastAndFutureExpiry() throws {
        // A plausible past timestamp must survive as a real Date, so an expired
        // account stays distinguishable from a never-expiring one.
        let past = #"{"user_info": {"auth": 1, "exp_date": 1600000000}}"#
        let future = #"{"user_info": {"auth": 1, "exp_date": "1803727680"}}"#

        let pastStatus = try XCTUnwrap(JSONDecoder().decode(AccountInfoDTO.self, from: Data(past.utf8)).userInfo).toDomain()
        let futureStatus = try XCTUnwrap(JSONDecoder().decode(AccountInfoDTO.self, from: Data(future.utf8)).userInfo).toDomain()

        XCTAssertEqual(pastStatus.expiryDate, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(futureStatus.expiryDate, Date(timeIntervalSince1970: 1_803_727_680))
    }
}
