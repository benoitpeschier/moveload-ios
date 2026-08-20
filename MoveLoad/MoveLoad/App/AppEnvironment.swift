import Foundation
import SwiftData
import Observation
import MoveLoadCore
import SensorKit
import AnalysisEngine
import PersistenceKit
import SyncKit
import MovesenseVendor

/// Composition root: owns the sensor service, the SwiftData container and the
/// repositories, and wires AnalysisEngine's pure functions to PersistenceKit's
/// storage. This is the only place that depends on all four packages at once —
/// swapping MockSensorService for the real Movesense SDK later only touches
/// the `sensorService` initializer argument here.
@MainActor
@Observable
final class AppEnvironment {
    let sensorService: SensorService
    let syncService: SyncService
    let syncSettingsStore = SyncSettingsStore()
    let modelContainer: ModelContainer
    private let athleteRepository = AthleteRepository()
    private let sessionRepository = SessionRepository()

    private(set) var athlete: Athlete!

    var modelContext: ModelContext { modelContainer.mainContext }

    init(sensorService: SensorService = MovesenseSensorService(), syncService: SyncService = FirestoreSyncService(), inMemory: Bool = false) {
        self.sensorService = sensorService
        self.syncService = syncService
        self.modelContainer = try! PersistenceContainer.make(inMemory: inMemory)
    }

    func bootstrap() throws {
        athlete = try athleteRepository.fetchOrCreateSingleAthlete(in: modelContext)
        migrateSessionCurvesIfNeeded()
    }

    /// One-time-per-launch fixup, for sessions whose stored numbers no longer
    /// mean what the current analysis means: either the mechanical window set
    /// changed, or the analysis generation did. Everything is recomputed from
    /// the still-on-disk raw samples, so history stays comparable rather than
    /// mixing results from two different definitions. A cheap no-op once
    /// everything is current.
    private func migrateSessionCurvesIfNeeded() {
        let currentSeconds = Set(MechanicalWindow.allCases.map(\.seconds))
        guard let sessions = try? allSessions() else { return }

        var recomputedAny = false
        for session in sessions {
            let windowsChanged = Set(session.curvePoints.map(\.windowSeconds)) != currentSeconds
            let generationStale = session.analysisVersion < AnalysisGeneration.current
            guard windowsChanged || generationStale else { continue }

            let directory = PersistenceContainer.documentsSessionsDirectory()
                .appendingPathComponent(session.rawSampleDirectory)
            guard let raw = try? RawSampleFileStore.read(startDate: session.startDate, from: directory) else { continue }

            // Re-run the whole analysis rather than the curve alone: zone times
            // are computed from the same signal and would otherwise be left on
            // the old scale.
            let settings = athlete.settings!
            let result = SessionAnalyzer.analyze(
                session: raw,
                settings: AnalysisSettings(
                    hrThresholdLow: settings.hrThresholdLow,
                    hrThresholdHigh: settings.hrThresholdHigh,
                    mechZonePercentLow: settings.mechZonePercentLow,
                    mechZonePercentHigh: settings.mechZonePercentHigh,
                    confirmedMech45sAnchor: settings.confirmedMech45sAnchor
                )
            )

            session.hrZoneI1Seconds = result.hrZoneSeconds[.i1] ?? 0
            session.hrZoneI2Seconds = result.hrZoneSeconds[.i2] ?? 0
            session.hrZoneI3Seconds = result.hrZoneSeconds[.i3] ?? 0
            session.mechZone1Seconds = result.mechZoneSeconds[.zone1] ?? 0
            session.mechZone2Seconds = result.mechZoneSeconds[.zone2] ?? 0
            session.mechZone3Seconds = result.mechZoneSeconds[.zone3] ?? 0
            session.mechZoneAnchorUsed = result.mechZoneAnchorUsed
            session.excludedWalkingSeconds = result.excludedWalkingSeconds
            session.inactiveSeconds = result.inactiveSeconds
            session.analysisVersion = AnalysisGeneration.current

            try? sessionRepository.replaceCurvePoints(for: session, curve: result.curve, in: modelContext)
            recomputedAny = true
            syncSessionInBackground(session)
        }

        // The confirmed 45 s reference was measured on the old signal, where
        // gravity inflated everything by roughly five- to sevenfold. Carrying
        // it over would put every mechanical zone permanently in zone 1, which
        // reads as a real result rather than a stale setting — so it is cleared
        // and the athlete is asked to confirm a new one.
        if recomputedAny, let settings = athlete.settings, settings.confirmedMech45sAnchor > 0 {
            settings.confirmedMech45sAnchor = 0
            settings.confirmedMech45sAnchorDate = nil
            settings.confirmedMech45sAnchorSessionID = nil
        }
        try? modelContext.save()
    }

    struct ImportOutcome {
        let session: Session
        /// Non-nil when this session's 45s peak beats the currently confirmed
        /// anchor — the UI should offer to update the mechanical zones.
        let candidateNewAnchor: Double?
        /// True when this recording was already imported and nothing new was
        /// created.
        var wasAlreadyImported: Bool = false
    }

    func importSession(raw: RawSessionData, logbookEntryID: String) throws -> ImportOutcome {
        // Recordings stay on the sensor after import, and the recovery path
        // re-walks ids from the start, so the same log reaches here more than
        // once. Returning the existing session keeps that from silently
        // duplicating an athlete's history.
        if let existing = try sessionRepository.session(
            withLogbookEntryID: logbookEntryID,
            startDate: raw.startDate,
            in: modelContext
        ) {
            return ImportOutcome(session: existing, candidateNewAnchor: nil, wasAlreadyImported: true)
        }
        return try createImportedSession(raw: raw, logbookEntryID: logbookEntryID)
    }

    private func createImportedSession(raw: RawSessionData, logbookEntryID: String) throws -> ImportOutcome {
        let settings = athlete.settings!

        let analysisSettings = AnalysisSettings(
            hrThresholdLow: settings.hrThresholdLow,
            hrThresholdHigh: settings.hrThresholdHigh,
            mechZonePercentLow: settings.mechZonePercentLow,
            mechZonePercentHigh: settings.mechZonePercentHigh,
            confirmedMech45sAnchor: settings.confirmedMech45sAnchor
        )
        let result = SessionAnalyzer.analyze(session: raw, settings: analysisSettings)

        let sessionID = UUID()
        let directory = PersistenceContainer.documentsSessionsDirectory().appendingPathComponent(sessionID.uuidString)
        try RawSampleFileStore.write(raw, to: directory)

        let session = try sessionRepository.createSession(
            id: sessionID,
            from: raw,
            analysis: result,
            athlete: athlete,
            logbookEntryID: logbookEntryID,
            rawSampleDirectory: directory.lastPathComponent,
            in: modelContext
        )

        let newPeak = result.peak45s ?? 0
        let candidateAnchor = newPeak > settings.confirmedMech45sAnchor ? newPeak : nil

        syncSessionInBackground(session)

        return ImportOutcome(session: session, candidateNewAnchor: candidateAnchor)
    }

    /// Fire-and-forget push to the coach webapp's backend — the session is
    /// already safely stored locally regardless of sync outcome, so failures
    /// here are silent. Call again after any edit that should reach the
    /// webapp (boat type, RPE) — see `SessionDetailView`.
    func syncSessionInBackground(_ session: Session) {
        let payload = sessionSyncPayload(for: session)
        Task { try? await syncService.pushSession(payload) }
    }

    /// Explicit re-push of athlete + every local session — the Settings
    /// "Synchroniser maintenant" button and first-time historical catch-up.
    /// Throws (unlike the fire-and-forget path above) so the button can show
    /// success/failure to the user.
    func syncAllSessionsNow() async throws {
        try await syncService.pushAthlete(athleteSyncPayload())
        for session in try allSessions() {
            try await syncService.pushSession(sessionSyncPayload(for: session))
        }
    }

    private func athleteSyncPayload() -> AthleteSyncPayload {
        AthleteSyncPayload(
            id: athlete.id.uuidString,
            name: athlete.name ?? "",
            gender: athlete.settings?.gender == .female ? "F" : "H"
        )
    }

    private func sessionSyncPayload(for session: Session) -> SessionSyncPayload {
        var peaks: [String: Double?] = [:]
        for window in MechanicalWindow.allCases {
            let point = session.curvePoints.first { $0.window == window }
            peaks[String(Int(window.seconds))] = point?.peakValue
        }
        return SessionSyncPayload(
            id: session.id.uuidString,
            athleteId: athlete.id.uuidString,
            athleteName: athlete.name ?? "",
            gender: athlete.settings?.gender == .female ? "F" : "H",
            boatType: session.boatType?.rawValue ?? "",
            date: session.startDate,
            durationSeconds: session.duration,
            name: session.name ?? "",
            perceivedExertion: session.perceivedExertion,
            isTest: session.isTest,
            hrZone1Seconds: session.hrZoneI1Seconds,
            hrZone2Seconds: session.hrZoneI2Seconds,
            hrZone3Seconds: session.hrZoneI3Seconds,
            mechZone1Seconds: session.mechZone1Seconds,
            mechZone2Seconds: session.mechZone2Seconds,
            mechZone3Seconds: session.mechZone3Seconds,
            mechanicalPeaks: peaks
        )
    }

    func confirmMechanicalZoneUpdate(newAnchor: Double, sessionID: UUID) throws {
        let settings = athlete.settings!
        settings.confirmedMech45sAnchor = newAnchor
        settings.confirmedMech45sAnchorDate = .now
        settings.confirmedMech45sAnchorSessionID = sessionID
        try modelContext.save()
    }

    func allSessions() throws -> [Session] {
        try sessionRepository.allSessions(in: modelContext)
    }

    /// Deletes a session and its on-disk raw accel/HR files. Curve points cascade
    /// via the SwiftData relationship — irreversible, the sensor's own logbook
    /// entry (if still present there) is untouched.
    func deleteSession(_ session: Session) async throws {
        let sessionID = session.id.uuidString
        let athleteID = athlete.id.uuidString

        // Retract it from the coach's dashboard *before* dropping the local
        // copy, and stop if that fails: deleting locally while the session
        // stays visible to the coach is precisely the gap this closes, and
        // once the local copy is gone there is nothing left to retry from.
        // An unconfigured sync is not a failure — there is no remote copy.
        do {
            try await syncService.deleteSession(id: sessionID, athleteId: athleteID)
        } catch SyncError.notConfigured {
            // Nothing was ever pushed.
        }

        let directory = PersistenceContainer.documentsSessionsDirectory()
            .appendingPathComponent(session.rawSampleDirectory)
        try? FileManager.default.removeItem(at: directory)
        modelContext.delete(session)
        try modelContext.save()
    }

    func liveRecords() throws -> [MechanicalWindow: Double] {
        let settings = athlete.settings!
        let cutoff = HistoryCutoff.cutoffDate(value: settings.recordsHistoryValue, unit: settings.recordsHistoryUnit)
        let peaks = try sessionRepository.historicalPeaks(after: cutoff, in: modelContext)
        let historicalPeaks = peaks.map { RecordCalculator.HistoricalPeak(window: $0.window, value: $0.value) }
        return RecordCalculator.liveRecords(from: historicalPeaks)
    }

    /// Demo-only: populates fake past sessions through MockSensorService so the
    /// Trends screen has something to show without waiting for real training
    /// history to accumulate. No-op against a real Movesense sensor.
    func seedDemoHistoryIfPossible(count: Int = 12, spanDays: Int = 60) async {
        guard let mock = sensorService as? MockSensorService else { return }
        mock.seedFakeHistory(sessionCount: count, spanDays: spanDays)

        for await sensor in sensorService.scan() {
            try? await sensorService.connect(to: sensor)
            break
        }
        guard let entries = try? await sensorService.listLogbookEntries() else { return }
        for entry in entries {
            guard let data = try? await sensorService.downloadEntry(entry, progress: { _ in }) else { continue }
            _ = try? importSession(raw: data, logbookEntryID: entry.id)
        }
    }

    /// Demo-only: seeds one deliberately dominant fake session (amplified
    /// acceleration) so it holds the live record on every mechanical window —
    /// a quick, deterministic way to check the "nouveau record" UI. No-op
    /// against a real Movesense sensor.
    func seedRecordSessionIfPossible() async {
        guard let mock = sensorService as? MockSensorService else { return }
        let entry = mock.seedRecordSession()

        for await sensor in sensorService.scan() {
            try? await sensorService.connect(to: sensor)
            break
        }
        guard let data = try? await sensorService.downloadEntry(entry, progress: { _ in }) else { return }
        _ = try? importSession(raw: data, logbookEntryID: entry.id)
    }
}
