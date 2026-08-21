import XCTest
@testable import SyncKit

final class SyncSettingsSharingTests: XCTestCase {
    private let settings = SyncSettings(
        teamCode: "kayak-7f3a91c2e8",
        projectID: "moveload-1a2b3",
        webAPIKey: "AIzaSyD-EXAMPLE_key_0123456789abcdefg"
    )

    func testRoundTrip() {
        let decoded = SyncSettings(shareablePayload: settings.shareablePayload)
        XCTAssertEqual(decoded, settings)
    }

    /// The team code is chosen by the user and is the only thing guarding the
    /// team's data, so it may well contain characters a URL cares about.
    func testSurvivesCharactersThatNeedEscaping() {
        let awkward = SyncSettings(
            teamCode: "équipe/canoë?a=1&b=2 #3+4",
            projectID: "p",
            webAPIKey: "k"
        )
        XCTAssertEqual(SyncSettings(shareablePayload: awkward.shareablePayload), awkward)
    }

    func testRejectsSomebodyElsesQRCode() {
        XCTAssertNil(SyncSettings(shareablePayload: "https://example.com/?c=a&p=b&k=c"))
        XCTAssertNil(SyncSettings(shareablePayload: "WIFI:S=network;T=WPA;P=secret;;"))
        XCTAssertNil(SyncSettings(shareablePayload: ""))
    }

    /// Half a configuration is worse than none: it looks set up in Settings
    /// and then never syncs, with nothing to say why.
    func testRejectsAPayloadMissingAField() {
        XCTAssertNil(SyncSettings(shareablePayload: "moveload://team?c=abc&p=def"))
        XCTAssertNil(SyncSettings(shareablePayload: "moveload://team?c=abc&p=def&k="))
    }
}

/// The coach webapp builds this payload in JavaScript, so the two encoders
/// have to agree. This exact string was produced by the webapp's
/// `invitePayload()` and pasted here; if either side changes its escaping,
/// this fails rather than athletes silently syncing nowhere.
///
/// Note the space encoded as %20, not "+": Swift's URLComponents reads "+"
/// as a literal plus, so the webapp must not use URLSearchParams.
final class WebappPayloadCompatibilityTests: XCTestCase {
    func testDecodesAPayloadBuiltByTheCoachWebapp() throws {
        let fromWebapp = "moveload://team?c=demo%20equipe%2Fcano%C3%AB%3Fx%3D1&p=appmoveload&k=AIzaSyDnSvSGlXZLKqRCgoiFqlkEFSpkPZ72YTU"
        let decoded = try XCTUnwrap(SyncSettings(shareablePayload: fromWebapp))

        XCTAssertEqual(decoded.teamCode, "demo equipe/canoë?x=1")
        XCTAssertEqual(decoded.projectID, "appmoveload")
        XCTAssertEqual(decoded.webAPIKey, "AIzaSyDnSvSGlXZLKqRCgoiFqlkEFSpkPZ72YTU")
    }
}
