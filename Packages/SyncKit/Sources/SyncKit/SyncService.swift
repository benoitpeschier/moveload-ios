import Foundation

public protocol SyncService: Sendable {
    /// Upserts the athlete's own doc (name + gender). Throws `SyncError.notConfigured`
    /// if sync isn't set up yet — callers decide whether to surface that or swallow it.
    func pushAthlete(_ athlete: AthleteSyncPayload) async throws

    /// Upserts the athlete doc (keeps name/gender fresh cheaply) then the session doc.
    func pushSession(_ session: SessionSyncPayload) async throws

    /// Removes a session from the coach's view. Without this, deleting a
    /// session on the phone left it visible to the coach forever, with no way
    /// to retract it from the app.
    func deleteSession(id: String, athleteId: String) async throws
    func pushHRVTest(_ test: HRVTestSyncPayload) async throws

    /// The fatigue thresholds the coach set for this athlete, or nil when they
    /// have set none. The coach owns them — the phone reads and never writes
    /// them — so that both screens read the same test the same way.
    func fetchHRVThresholds(athleteId: String) async throws -> [String: Double]?
}

/// Firestore-backed `SyncService`, built entirely on `AuthClient`/`FirestoreClient`'s
/// hand-rolled REST calls — see those files for why this avoids the firebase-ios-sdk.
public final class FirestoreSyncService: SyncService {
    private let settingsStore: SyncSettingsStore
    private let authClient: AuthClient

    public init(settingsStore: SyncSettingsStore = SyncSettingsStore(), authClient: AuthClient = AuthClient()) {
        self.settingsStore = settingsStore
        self.authClient = authClient
    }

    public func pushAthlete(_ athlete: AthleteSyncPayload) async throws {
        let settings = try requireSettings()
        try await upsertAthlete(athlete, settings: settings)
    }

    public func pushSession(_ session: SessionSyncPayload) async throws {
        let settings = try requireSettings()
        try await upsertAthlete(
            AthleteSyncPayload(id: session.athleteId, name: session.athleteName, gender: session.gender),
            settings: settings
        )
        try await upsertSession(session, settings: settings)
    }

    public func pushHRVTest(_ test: HRVTestSyncPayload) async throws {
        let settings = try requireSettings()
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        let client = FirestoreClient(projectID: settings.projectID, idToken: idToken)

        try await client.upsertDocument(
            pathComponents: ["teams", settings.teamCode, "athletes", test.athleteId, "hrv", test.id],
            fields: [
                "athleteId": .string(test.athleteId),
                "date": .timestamp(test.date),
                "supineMeanHR": .double(test.supineMeanHR),
                "supineRMSSD": .double(test.supineRMSSD),
                "supineTotalPower": .double(test.supineTotalPower),
                "supineLFOverHF": .double(test.supineLFOverHF),
                "supineLF": .double(test.supineLF),
                "supineHF": .double(test.supineHF),
                "standingMeanHR": .double(test.standingMeanHR),
                "standingRMSSD": .double(test.standingRMSSD),
                "standingTotalPower": .double(test.standingTotalPower),
                "standingLFOverHF": .double(test.standingLFOverHF),
                "standingLF": .double(test.standingLF),
                "standingHF": .double(test.standingHF),
                // The score, never the five answers — see HRVTestSyncPayload.
                "wellnessScore": test.wellnessScore.map(FirestoreValue.integer) ?? .null,
                "isReliable": .boolean(test.isReliable),
            ]
        )
    }

    public func fetchHRVThresholds(athleteId: String) async throws -> [String: Double]? {
        let settings = try requireSettings()
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        let client = FirestoreClient(projectID: settings.projectID, idToken: idToken)
        return try await client.fetchNumbers(
            pathComponents: ["teams", settings.teamCode, "athletes", athleteId, "config", "hrvThresholds"]
        )
    }

    public func deleteSession(id: String, athleteId: String) async throws {
        let settings = try requireSettings()
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        let client = FirestoreClient(projectID: settings.projectID, idToken: idToken)
        try await client.deleteDocument(
            pathComponents: ["teams", settings.teamCode, "athletes", athleteId, "sessions", id]
        )
    }

    private func requireSettings() throws -> SyncSettings {
        guard let settings = settingsStore.load(), settings.isConfigured else {
            throw SyncError.notConfigured
        }
        return settings
    }

    private func upsertAthlete(_ athlete: AthleteSyncPayload, settings: SyncSettings) async throws {
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        let client = FirestoreClient(projectID: settings.projectID, idToken: idToken)
        try await client.upsertDocument(
            pathComponents: ["teams", settings.teamCode, "athletes", athlete.id],
            fields: [
                "name": .string(athlete.name),
                "gender": .string(athlete.gender)
            ]
        )
    }

    private func upsertSession(_ session: SessionSyncPayload, settings: SyncSettings) async throws {
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        let client = FirestoreClient(projectID: settings.projectID, idToken: idToken)

        var peakFields: [String: FirestoreValue] = [:]
        for (window, value) in session.mechanicalPeaks {
            peakFields[window] = value.map(FirestoreValue.double) ?? .null
        }

        try await client.upsertDocument(
            pathComponents: ["teams", settings.teamCode, "athletes", session.athleteId, "sessions", session.id],
            fields: [
                "athleteId": .string(session.athleteId),
                "athleteName": .string(session.athleteName),
                "gender": .string(session.gender),
                "boatType": .string(session.boatType),
                "date": .timestamp(session.date),
                "durationSeconds": .double(session.durationSeconds),
                "perceivedExertion": session.perceivedExertion.map(FirestoreValue.integer) ?? .null,
                "isTest": .boolean(session.isTest),
                "isConditioning": .boolean(session.isConditioning),
                // The stroke waveform rides along for test sessions only. It is
                // ~470 doubles, which is nothing next to Firestore's 1 MB
                // document limit but adds up over a season of ordinary
                // training — and it is only on standardised tests that
                // comparing stroke shape means anything anyway.
                "bestNineSecondsSignal": session.isTest && !session.bestNineSecondsSignal.isEmpty
                    ? .array(session.bestNineSecondsSignal.map { .double(($0 * 1000).rounded() / 1000) })
                    : .null,
                "bestNineSecondsRateHz": session.isTest && !session.bestNineSecondsSignal.isEmpty
                    ? .double(session.bestNineSecondsRateHz)
                    : .null,
                "name": .string(session.name),
                "hrZone1Seconds": .double(session.hrZone1Seconds),
                "hrZone2Seconds": .double(session.hrZone2Seconds),
                "hrZone3Seconds": .double(session.hrZone3Seconds),
                "mechZone1Seconds": .double(session.mechZone1Seconds),
                "mechZone2Seconds": .double(session.mechZone2Seconds),
                "mechZone3Seconds": .double(session.mechZone3Seconds),
                "secondsAboveAnchor": .double(session.secondsAboveAnchor),
                "mechanicalPeaks": .map(peakFields)
            ]
        )
    }
}
