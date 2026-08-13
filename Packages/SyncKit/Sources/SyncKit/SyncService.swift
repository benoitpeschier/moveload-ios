import Foundation

public protocol SyncService: Sendable {
    /// Upserts the athlete's own doc (name + gender). Throws `SyncError.notConfigured`
    /// if sync isn't set up yet — callers decide whether to surface that or swallow it.
    func pushAthlete(_ athlete: AthleteSyncPayload) async throws

    /// Upserts the athlete doc (keeps name/gender fresh cheaply) then the session doc.
    func pushSession(_ session: SessionSyncPayload) async throws
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
                "hrZone1Seconds": .double(session.hrZone1Seconds),
                "hrZone2Seconds": .double(session.hrZone2Seconds),
                "hrZone3Seconds": .double(session.hrZone3Seconds),
                "mechZone1Seconds": .double(session.mechZone1Seconds),
                "mechZone2Seconds": .double(session.mechZone2Seconds),
                "mechZone3Seconds": .double(session.mechZone3Seconds),
                "mechanicalPeaks": .map(peakFields)
            ]
        )
    }
}
