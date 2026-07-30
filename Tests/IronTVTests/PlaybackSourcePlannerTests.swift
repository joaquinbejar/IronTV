import XCTest
@testable import IronTV

final class PlaybackSourcePlannerTests: XCTestCase {

    private let panelHost = URL(string: "http://host.example.com:8080")!
    private let sameHostDirect = URL(string: "http://host.example.com:8080/direct/1.m3u8")!

    private func plan(direct: URL? = nil, formats: Set<StreamOutputFormat>?) -> PlaybackSourceSelection {
        PlaybackSourcePlanner.plan(directSource: direct, allowedFormats: formats, panelHost: panelHost)
    }

    func testAbsentFormatsAssumeBothClassicContainers() {
        let selection = plan(formats: nil)
        XCTAssertTrue(selection.useHLS)
        XCTAssertTrue(selection.useTS)
        XCTAssertTrue(selection.hasPlayableSource)
    }

    func testHLSOnlyAndTSOnlyPanels() {
        let hlsOnly = plan(formats: [.hls])
        XCTAssertTrue(hlsOnly.useHLS)
        XCTAssertFalse(hlsOnly.useTS)

        let tsOnly = plan(formats: [.ts])
        XCTAssertFalse(tsOnly.useHLS)
        XCTAssertTrue(tsOnly.useTS)
    }

    func testNothingAdvertisedAndNoDirectMeansNoPlayableSource() {
        let selection = plan(formats: [])
        XCTAssertFalse(selection.hasPlayableSource)
    }

    func testTrustedDirectSourceRequiresSchemeAndSamePanelHost() {
        XCTAssertEqual(plan(direct: sameHostDirect, formats: []).directURL, sameHostDirect)
        // Host comparison is case-insensitive.
        XCTAssertNotNil(plan(direct: URL(string: "http://HOST.EXAMPLE.COM:8080/x.m3u8"), formats: []).directURL)

        // Same host on a different port is a different service — rejected,
        // consistent with the same-origin rule everywhere else.
        XCTAssertNil(plan(direct: URL(string: "http://host.example.com:9999/x.m3u8"), formats: []).directURL)
        XCTAssertNil(plan(direct: URL(string: "http://host.example.com/x.m3u8"), formats: []).directURL,
                     "default port 80 differs from the panel's 8080")

        // Cross-host: a redirect of credentials/tokens to a server the user
        // never entered — rejected.
        XCTAssertNil(plan(direct: URL(string: "http://cdn.other.com/x.m3u8"), formats: []).directURL)
        // Non-web schemes rejected.
        XCTAssertNil(plan(direct: URL(string: "rtmp://host.example.com/x"), formats: []).directURL)
        // Hostless / relative junk rejected.
        XCTAssertNil(plan(direct: URL(string: "not a url")?.absoluteURL, formats: []).directURL)
    }

    func testDirectSourceAloneIsAPlayableSource() {
        let selection = plan(direct: sameHostDirect, formats: [])
        XCTAssertTrue(selection.hasPlayableSource)
    }
}
