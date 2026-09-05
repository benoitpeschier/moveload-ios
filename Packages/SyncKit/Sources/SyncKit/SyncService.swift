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

    /// Retracts a morning test. Same reasoning as `deleteSession`: a trial run
    /// deleted on the phone but left standing on the dashboard would go on
    /// shifting the coach's six-test median for weeks.
    func deleteHRVTest(id: String, athleteId: String) async throws

    /// The fatigue thresholds the coach set for this athlete, or nil when they
    /// have set none. The coach owns them — the phone reads and never writes
    /// them — so that both screens read the same test the same way.
    func fetchHRVThresholds(athleteId: String) async throws -> [String: Double]?
    func fetchCoachNotes(athleteId: String) async throws -> [String: String]?

    // MARK: - Account

    /// Who this device is signed in as, or nil when it has never signed in.
    /// An `isAnonymous` account is the pre-account behaviour: it still syncs,
    /// but it belongs to this install and nothing else.
    func currentAccount() async -> AuthAccount?
    func createAccount(email: String, password: String) async throws -> AuthAccount
    func signIn(email: String, password: String) async throws -> AuthAccount
    func signOut() async
}

/// Remembers that a person's membership documents are in place, so the check
/// costs one read and two writes per launch rather than per push.
///
/// An actor rather than a stored flag: `FirestoreSyncService` is a Sendable
/// class called from several background tasks at once, and a plain `var` there
/// is a data race. Reentrancy can still let two simultaneous first pushes both
/// run the work, which is harmless — the writes are idempotent, and the point
/// is to avoid doing it on every push, not to make it exactly-once.
private actor MembershipCache {
    private var ensuredFor: String?

    func ensure(_ key: String, _ work: () async throws -> Void) async throws {
        guard ensuredFor != key else { return }
        try await work()
        ensuredFor = key
    }
}

/// Firestore-backed `SyncService`, built entirely on `AuthClient`/`FirestoreClient`'s
/// hand-rolled REST calls — see those files for why this avoids the firebase-ios-sdk.
public final class FirestoreSyncService: SyncService {
    private let settingsStore: SyncSettingsStore
    private let authClient: AuthClient
    private let membership = MembershipCache()

    public init(settingsStore: SyncSettingsStore = SyncSettingsStore(), authClient: AuthClient = AuthClient()) {
        self.settingsStore = settingsStore
        self.authClient = authClient
    }

    public func pushAthlete(_ athlete: AthleteSyncPayload) async throws {
        try await upsertAthlete(athlete, connection: try await connect())
    }

    public func pushSession(_ session: SessionSyncPayload) async throws {
        let connection = try await connect()
        try await upsertAthlete(
            AthleteSyncPayload(id: session.athleteId, name: session.athleteName, gender: session.gender),
            connection: connection
        )
        try await upsertSession(session, connection: connection)
    }

    public func pushHRVTest(_ test: HRVTestSyncPayload) async throws {
        let connection = try await connect()
        try await connection.client.upsertDocument(
            pathComponents: ["athletes", test.athleteId, "hrv", test.id],
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
                "supineRR": .array(test.supineRRms.map(FirestoreValue.integer)),
                "standingRR": .array(test.standingRRms.map(FirestoreValue.integer)),
            ]
        )
    }

    /// The coach's remarks, one per test, read by the athlete's phone.
    ///
    /// One document with a field per test id rather than a collection: reading
    /// them all is then a single request, and the REST client needs no listing
    /// it does not already have. Same ownership as `config/hrvThresholds` — the
    /// coach writes, the phone only ever reads, so there is no write conflict
    /// to resolve.
    public func fetchCoachNotes(athleteId: String) async throws -> [String: String]? {
        let connection = try await connect()
        return try await connection.client.fetchStrings(
            pathComponents: ["athletes", athleteId, "config", "coachNotes"]
        )
    }

    public func currentAccount() async -> AuthAccount? {
        await authClient.currentAccount()
    }

    public func createAccount(email: String, password: String) async throws -> AuthAccount {
        let settings = try requireSettings()
        return try await authClient.createAccount(
            email: normalised(email), password: password, webAPIKey: settings.webAPIKey)
    }

    public func signIn(email: String, password: String) async throws -> AuthAccount {
        let settings = try requireSettings()
        return try await authClient.signIn(
            email: normalised(email), password: password, webAPIKey: settings.webAPIKey)
    }

    public func signOut() async {
        await authClient.signOut()
    }

    /// iOS's e-mail keyboard happily leaves a trailing space, and an address
    /// typed with a capital first letter is the same address.
    private func normalised(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func fetchHRVThresholds(athleteId: String) async throws -> [String: Double]? {
        let connection = try await connect()
        return try await connection.client.fetchNumbers(
            pathComponents: ["athletes", athleteId, "config", "hrvThresholds"]
        )
    }

    public func deleteSession(id: String, athleteId: String) async throws {
        let connection = try await connect()
        try await connection.client.deleteDocument(
            pathComponents: ["athletes", athleteId, "sessions", id]
        )
    }

    public func deleteHRVTest(id: String, athleteId: String) async throws {
        let connection = try await connect()
        try await connection.client.deleteDocument(
            pathComponents: ["athletes", athleteId, "hrv", id]
        )
    }

    /// Everything a write needs, with the caller's membership documents
    /// already in place.
    ///
    /// Order matters: under the team rules, every athlete path is authorised
    /// by reading the caller's `users/{uid}` document, so writing an athlete
    /// before that document exists is refused. This is the one funnel where
    /// that ordering can be guaranteed.
    private struct Connection {
        let client: FirestoreClient
        let uid: String
        let teamId: String
    }

    private func connect() async throws -> Connection {
        let settings = try requireSettings()
        let idToken = try await authClient.validIDToken(webAPIKey: settings.webAPIKey)
        guard let uid = FirebaseIDToken.uid(from: idToken) else {
            throw AuthError.notSignedIn
        }
        let connection = Connection(
            client: FirestoreClient(projectID: settings.projectID, idToken: idToken),
            uid: uid,
            // The team code has always been long and random, so it serves as
            // the team's id unchanged — no mapping table, and no settings to
            // migrate on anybody's phone.
            teamId: settings.teamCode
        )
        try await ensureMembership(connection)
        return connection
    }

    private func ensureMembership(_ connection: Connection) async throws {
        try await membership.ensure("\(connection.uid)|\(connection.teamId)") {
        // Read before write: the phone knows the one team it is configured
        // for, and a plain overwrite would drop this person out of every
        // other team they belong to.
        var teamIds = try await connection.client.fetchStringArray(
            pathComponents: ["users", connection.uid], field: "teamIds")
        if !teamIds.contains(connection.teamId) {
            teamIds.append(connection.teamId)
        }

        try await connection.client.upsertDocument(
            pathComponents: ["users", connection.uid],
            fields: ["teamIds": .array(teamIds.map(FirestoreValue.string))]
        )
        try await connection.client.upsertDocument(
            pathComponents: ["teams", connection.teamId, "members", connection.uid],
            fields: ["role": .string("athlete")]
        )
        }
    }

    private func requireSettings() throws -> SyncSettings {
        guard let settings = settingsStore.load(), settings.isConfigured else {
            throw SyncError.notConfigured
        }
        return settings
    }

    private func upsertAthlete(_ athlete: AthleteSyncPayload, connection: Connection) async throws {
        // Read-modify-write for the same reason as the user document: an
        // athlete belongs to as many teams as they belong to, and this phone
        // only knows about one of them.
        var teamIds = try await connection.client.fetchStringArray(
            pathComponents: ["athletes", athlete.id], field: "teamIds")
        if !teamIds.contains(connection.teamId) {
            teamIds.append(connection.teamId)
        }

        try await connection.client.upsertDocument(
            pathComponents: ["athletes", athlete.id],
            fields: [
                "name": .string(athlete.name),
                "gender": .string(athlete.gender),
                "teamIds": .array(teamIds.map(FirestoreValue.string)),
                // Which account this profile belongs to, so a coach's own
                // athlete profile and their coaching seat are one person.
                "userId": .string(connection.uid)
            ]
        )

        // The squad's roster entry. Name and gender only — enough for the
        // dashboard to draw a card and then go and read the real data at
        // athletes/{id}. This is what replaces listing a team subcollection,
        // and it is why the athletes collection never has to be enumerable.
        try await connection.client.upsertDocument(
            pathComponents: ["teams", connection.teamId, "roster", athlete.id],
            fields: [
                "name": .string(athlete.name),
                "gender": .string(athlete.gender)
            ]
        )
    }

    private func upsertSession(_ session: SessionSyncPayload, connection: Connection) async throws {
        var peakFields: [String: FirestoreValue] = [:]
        for (window, value) in session.mechanicalPeaks {
            peakFields[window] = value.map(FirestoreValue.double) ?? .null
        }

        try await connection.client.upsertDocument(
            pathComponents: ["athletes", session.athleteId, "sessions", session.id],
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
