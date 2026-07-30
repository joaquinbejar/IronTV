import XCTest
@testable import IronTV

/// Regression guards for the two hot paths a very large catalog exercises:
/// decoding the full stream list and filtering it. Fixtures are generated
/// in-process (a 50k-row JSON file would bloat the repo), in the panel's
/// wire shape — numerics alternating between Int and String like real PHP
/// panels do.
///
/// Budget policy: the `measure` blocks record baselines for local profiling;
/// the hard assertions are deliberately loose (an order of magnitude above
/// the observed cost on a laptop) so CI machine variance can never flake
/// them — they only catch an accidental complexity regression, e.g. the
/// filter going quadratic or decode falling off tolerant-decoding fast paths.
final class CatalogPerformanceTests: XCTestCase {

    private static func syntheticCatalogData(count: Int) -> Data {
        var rows: [String] = []
        rows.reserveCapacity(count)
        for index in 1...count {
            let id = index % 2 == 0 ? "\(index)" : "\"\(index)\""
            rows.append(
                "{\"num\": \(index), \"name\": \"Channel \(index) HD\", \"stream_id\": \(id), " +
                "\"stream_icon\": \"\", \"epg_channel_id\": null, \"category_id\": \"\(index % 40)\"}"
            )
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    private static func syntheticStreams(count: Int) -> [LiveStream] {
        (1...count).map { index in
            LiveStream(
                id: StreamID(index),
                name: index % 100 == 0 ? "Café Match \(index)" : "Channel \(index) HD",
                iconURL: nil,
                categoryID: CategoryID(index % 40),
                epgChannelID: nil
            )
        }
    }

    func testDecoding10kCatalogMeetsTheBudget() throws {
        let data = Self.syntheticCatalogData(count: 10_000)

        // Correctness first: every synthetic row survives tolerant decoding
        // and maps to a domain stream.
        let dtos = try JSONDecoder().decode([LiveStreamDTO].self, from: data)
        XCTAssertEqual(dtos.compactMap { $0.toDomain() }.count, 10_000)

        // Observed ~0.1 s on a laptop; the assert allows 10×.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = try? JSONDecoder().decode([LiveStreamDTO].self, from: data)
        }
        XCTAssertLessThan(elapsed, .seconds(5), "decoding 10k rows regressed far beyond machine variance")

        measure {
            _ = try? JSONDecoder().decode([LiveStreamDTO].self, from: data)
        }
    }

    func testFiltering50kStreamsMeetsTheBudget() {
        let streams = Self.syntheticStreams(count: 50_000)

        // Correctness first: the diacritic-insensitive match finds exactly
        // the seeded rows.
        XCTAssertEqual(ChannelsViewModel.filter(streams, query: "cafe").count, 500)

        // Observed ~0.05 s on a laptop; the assert allows well over 10×.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = ChannelsViewModel.filter(streams, query: "match")
        }
        XCTAssertLessThan(elapsed, .seconds(2), "filtering 50k rows regressed far beyond machine variance")

        measure {
            _ = ChannelsViewModel.filter(streams, query: "match")
        }
    }
}
