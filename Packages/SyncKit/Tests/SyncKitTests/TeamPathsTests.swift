import XCTest
@testable import SyncKit

/// Pins the shape the team model depends on: where documents live, and the
/// order they are written in.
///
/// The ordering is not cosmetic. Under the team rules every athlete path is
/// authorised by reading the caller's `users/{uid}` document, so an athlete
/// written before that document exists is refused — a failure that would only
/// show up against a live project.
final class TeamPathsTests: XCTestCase {
    private var settingsStore: SyncSettingsStore!
    private var recorded: [(method: String, path: String)] = []

    private let uid = "uid-abc"

    override func setUp() {
        super.setUp()
        // FirestoreSyncService builds its own FirestoreClient on URLSession
        // .shared, so the stub is registered globally rather than injected.
        URLProtocol.registerClass(StubURLProtocol.self)
        recorded = []

        let defaults = UserDefaults(suiteName: "TeamPathsTests")!
        defaults.removePersistentDomain(forName: "TeamPathsTests")
        settingsStore = SyncSettingsStore(defaults: defaults)
        settingsStore.save(SyncSettings(teamCode: "TEAM-XYZ", projectID: "proj1", webAPIKey: "KEY"))

        StubURLProtocol.requestHandler = { [self] request in
            let url = request.url!.absoluteString
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!

            if url.contains("identitytoolkit") {
                // A real-looking anonymous sign-up, whose token carries the uid.
                let claims = try! JSONSerialization.data(withJSONObject: ["user_id": uid])
                let payload = claims.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                return (ok, Data("""
                {"idToken":"h.\(payload).s","refreshToken":"r","expiresIn":"3600","localId":"\(uid)"}
                """.utf8))
            }

            let marker = "/documents/"
            let path = String(url[url.range(of: marker)!.upperBound...])
            recorded.append((request.httpMethod ?? "?", path))
            // Every read answers "document not found", which is the state of a
            // project that has never seen this athlete.
            if request.httpMethod == "GET" {
                return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            return (ok, Data("{}".utf8))
        }
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService() -> FirestoreSyncService {
        // A fresh AuthClient each time, so the Keychain state of the machine
        // running the tests cannot decide what the uid is.
        FirestoreSyncService(settingsStore: settingsStore, authClient: AuthClient())
    }

    private var writtenPaths: [String] { recorded.filter { $0.method == "PATCH" }.map(\.path) }

    func testSessionLivesUnderTheAthleteNotUnderTheTeam() async throws {
        try await makeService().pushSession(
            SessionSyncPayload.fixture(athleteId: "ath1", id: "sess1"))

        XCTAssertTrue(writtenPaths.contains("athletes/ath1/sessions/sess1"),
                      "wrote: \(writtenPaths)")
        // The whole point of the migration: no team code anywhere in the data
        // path, so an athlete in two teams has one copy of every session.
        XCTAssertFalse(writtenPaths.contains { $0.hasPrefix("teams/TEAM-XYZ/athletes") },
                       "wrote: \(writtenPaths)")
    }

    func testTeamKeepsOnlyARosterPointer() async throws {
        try await makeService().pushSession(
            SessionSyncPayload.fixture(athleteId: "ath1", id: "sess1"))

        // Discovery lives under the team; the data does not. Without this the
        // dashboard would have to enumerate every athlete in the project.
        XCTAssertTrue(writtenPaths.contains("teams/TEAM-XYZ/roster/ath1"),
                      "wrote: \(writtenPaths)")
    }

    func testMembershipIsWrittenBeforeTheAthlete() async throws {
        try await makeService().pushSession(
            SessionSyncPayload.fixture(athleteId: "ath1", id: "sess1"))

        let user = try XCTUnwrap(writtenPaths.firstIndex(of: "users/\(uid)"))
        let athlete = try XCTUnwrap(writtenPaths.firstIndex(of: "athletes/ath1"))
        XCTAssertLessThan(user, athlete,
                          "the rules read users/{uid} to authorise the athlete write")
        XCTAssertTrue(writtenPaths.contains("teams/TEAM-XYZ/members/\(uid)"),
                      "wrote: \(writtenPaths)")
    }

    func testMembershipIsEstablishedOncePerServiceNotOncePerPush() async throws {
        let service = makeService()
        try await service.pushSession(SessionSyncPayload.fixture(athleteId: "ath1", id: "s1"))
        let afterFirst = writtenPaths.filter { $0 == "users/\(uid)" }.count
        try await service.pushSession(SessionSyncPayload.fixture(athleteId: "ath1", id: "s2"))

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(writtenPaths.filter { $0 == "users/\(uid)" }.count, 1,
                       "the second push re-established a membership it already had")
    }

    func testHRVAndThresholdsMovedTooAndDeletionFollows() async throws {
        let service = makeService()
        try await service.pushHRVTest(HRVTestSyncPayload.fixture(athleteId: "ath1", id: "t1"))
        XCTAssertTrue(writtenPaths.contains("athletes/ath1/hrv/t1"), "wrote: \(writtenPaths)")

        _ = try? await service.fetchHRVThresholds(athleteId: "ath1")
        XCTAssertTrue(recorded.contains { $0.path == "athletes/ath1/config/hrvThresholds" },
                      "read: \(recorded)")

        try await service.deleteSession(id: "s1", athleteId: "ath1")
        XCTAssertTrue(recorded.contains { $0.method == "DELETE" && $0.path == "athletes/ath1/sessions/s1" },
                      "requested: \(recorded)")
    }
}

// MARK: - Fixtures

extension SessionSyncPayload {
    /// Only the fields these tests read matter; the rest is plausible filler.
    static func fixture(athleteId: String, id: String) -> SessionSyncPayload {
        SessionSyncPayload(
            id: id, athleteId: athleteId, athleteName: "Jane", gender: "F",
            boatType: "K1", date: Date(timeIntervalSince1970: 1_756_000_000),
            durationSeconds: 2400, perceivedExertion: 6,
            isTest: false, isConditioning: false,
            hrZone1Seconds: 1800, hrZone2Seconds: 500, hrZone3Seconds: 100,
            mechZone1Seconds: 1500, mechZone2Seconds: 600, mechZone3Seconds: 300,
            mechanicalPeaks: ["45": 3.2]
        )
    }
}

extension HRVTestSyncPayload {
    static func fixture(athleteId: String, id: String) -> HRVTestSyncPayload {
        let position = HRVPositionMetrics(
            meanHR: 52, rmssd: 61, totalPower: 3400,
            lfOverHF: 0.8, lf: 900, hf: 1100, isReliable: true)
        return HRVTestSyncPayload(
            id: id, athleteId: athleteId, date: Date(timeIntervalSince1970: 1_700_000_000),
            supine: position, standing: position,
            wellnessScore: 80,
            supineRRms: [1000, 1010, 990], standingRRms: [800, 810, 790])
    }
}
