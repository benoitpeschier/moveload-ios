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

    /// The last background sync failure, or nil when the last one worked.
    ///
    /// Background pushes deliberately do not interrupt the athlete mid-session,
    /// but swallowing the error outright is how a Firestore rule that never
    /// covered the `hrv` subcollection stayed invisible: every morning test was
    /// refused, on the phone and on the dashboard, and nothing anywhere said so.
    /// Settings shows this so there is one place to look.
    private(set) var lastBackgroundSyncError: String?

    var modelContext: ModelContext { modelContainer.mainContext }

    init(sensorService: SensorService = MovesenseSensorService(), syncService: SyncService = FirestoreSyncService(), inMemory: Bool = false) {
        self.sensorService = sensorService
        self.syncService = syncService
        self.modelContainer = try! PersistenceContainer.make(inMemory: inMemory)
    }

    func bootstrap() throws {
        athlete = try athleteRepository.fetchOrCreateSingleAthlete(in: modelContext)
        // Moving the thresholds changes what every stored zone time means, so
        // the session pass is told to recompute everything rather than only
        // what its own staleness checks would catch — on an install that has
        // already migrated, those checks find nothing.
        let thresholdsMoved = migrateZoneThresholdsIfNeeded()
        migrateSessionCurvesIfNeeded(forceAll: thresholdsMoved)
    }

    /// One-time-per-launch fixup, for sessions whose stored numbers no longer
    /// mean what the current analysis means: either the mechanical window set
    /// changed, or the analysis generation did. Everything is recomputed from
    /// the still-on-disk raw samples, so history stays comparable rather than
    /// mixing results from two different definitions. A cheap no-op once
    /// everything is current.
    /// Moves the zone thresholds onto the rolling-mean scale, once.
    ///
    /// Only when they are still exactly the old defaults: a coach who chose
    /// their own figures meant them, and having the app quietly overwrite a
    /// deliberate setting is worse than leaving it alone.
    @discardableResult
    private func migrateZoneThresholdsIfNeeded() -> Bool {
        guard let settings = athlete.settings, !settings.movedToRollingMeanThresholds else { return false }
        settings.movedToRollingMeanThresholds = true

        let atOldDefaults = abs(settings.mechZonePercentLow - 0.70) < 0.001
            && abs(settings.mechZonePercentHigh - 0.90) < 0.001
        if atOldDefaults {
            settings.mechZonePercentLow = 0.35
            settings.mechZonePercentHigh = 0.55
        }
        try? modelContext.save()
        return atOldDefaults
    }

    private func migrateSessionCurvesIfNeeded(forceAll: Bool = false) {
        let currentSeconds = Set(MechanicalWindow.allCases.map(\.seconds))
        guard let sessions = try? allSessions() else { return }

        var recomputedAny = false
        var crossedGravityFix = false
        for session in sessions {
            let windowsChanged = Set(session.curvePoints.map(\.windowSeconds)) != currentSeconds
            let generationStale = session.analysisVersion < AnalysisGeneration.current
            guard forceAll || windowsChanged || generationStale else { continue }

            let directory = PersistenceContainer.documentsSessionsDirectory()
                .appendingPathComponent(session.rawSampleDirectory)
            guard let raw = try? RawSampleFileStore.read(startDate: session.startDate, from: directory) else { continue }

            // Re-run the whole analysis rather than the curve alone: zone times
            // are computed from the same signal and would otherwise be left on
            // the old scale.
            if session.analysisVersion < AnalysisGeneration.gravityRemoved { crossedGravityFix = true }
            reanalyse(session, from: raw)
            recomputedAny = true
        }

        // Only the gravity fix invalidated the reference: it was measured on a
        // signal five- to sevenfold larger, so carrying it over would have put
        // every zone permanently in zone 1. Later migrations change how the
        // signal is *read*, not its scale, and clearing the reference for those
        // silently threw away a measurement the athlete had to go out and make.
        if crossedGravityFix, let settings = athlete.settings, settings.confirmedMech45sAnchor > 0 {
            settings.confirmedMech45sAnchor = 0
            settings.confirmedMech45sAnchorDate = nil
            settings.confirmedMech45sAnchorSessionID = nil
        }
        try? modelContext.save()
    }

    /// The sensor this app is paired with, or nil until one is chosen.
    var pairedSensorSerial: String? {
        get {
            let value = athlete.settings?.pairedSensorSerial ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            athlete.settings?.pairedSensorSerial = newValue ?? ""
            try? modelContext.save()
        }
    }

    enum ImportError: LocalizedError {
        case wrongSensor(found: String, expected: String)

        var errorDescription: String? {
            switch self {
            case let .wrongSensor(found, expected):
                // Named rather than vague: in a clubhouse the athlete needs to
                // know it is somebody else's sensor, not that "something went
                // wrong", so they stop instead of retrying.
                return """
                    Cette séance vient du capteur \(found), pas du tien (\(expected)). \
                    Elle n'a pas été importée. Déconnecte-toi et reconnecte-toi à ton capteur — \
                    et surtout n'efface pas la mémoire de celui-ci, elle appartient à quelqu'un d'autre.
                    """
            }
        }
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

    /// - Parameter sensorSerial: the sensor the recording was read from, or
    ///   empty when the source cannot say (the Showcase JSON import). Empty
    ///   means unknown, so it is allowed through rather than rejected.
    func importSession(
        raw: RawSessionData,
        logbookEntryID: String,
        sensorSerial: String = ""
    ) throws -> ImportOutcome {
        // Refuse a recording from anyone else's sensor before it can reach the
        // athlete's history — and, through sync, the coach's dashboard under
        // the wrong name. Once stored it is indistinguishable from a real one.
        if let paired = pairedSensorSerial, !sensorSerial.isEmpty, sensorSerial != paired {
            throw ImportError.wrongSensor(found: sensorSerial, expected: paired)
        }

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
        return try createImportedSession(raw: raw, logbookEntryID: logbookEntryID, sensorSerial: sensorSerial)
    }

    private func createImportedSession(
        raw: RawSessionData,
        logbookEntryID: String,
        sensorSerial: String
    ) throws -> ImportOutcome {
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
            sensorSerial: sensorSerial,
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
        Task { await pushInBackground { try await self.syncService.pushSession(payload) } }
    }

    /// Runs a background push and remembers whether it worked. Still silent to
    /// the athlete — it never throws and never blocks — but no longer secret.
    private func pushInBackground(_ push: @escaping () async throws -> Void) async {
        do {
            try await push()
            lastBackgroundSyncError = nil
        } catch {
            lastBackgroundSyncError = error.localizedDescription
        }
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
            isConditioning: session.isConditioning,
            bestNineSecondsSignal: session.bestNineSecondsSignal,
            bestNineSecondsRateHz: session.bestNineSecondsRateHz,
            hrZone1Seconds: session.hrZoneI1Seconds,
            hrZone2Seconds: session.hrZoneI2Seconds,
            hrZone3Seconds: session.hrZoneI3Seconds,
            mechZone1Seconds: session.mechZone1Seconds,
            mechZone2Seconds: session.mechZone2Seconds,
            mechZone3Seconds: session.mechZone3Seconds,
            secondsAboveAnchor: session.secondsAboveAnchor,
            mechanicalPeaks: peaks
        )
    }

    /// Re-reads one session after the athlete changed what kind of session it
    /// is. Ticking the PPG box has to recompute rather than merely hide: the
    /// mechanical figures were produced with walking stripped out, and the
    /// cardiac ones were counted over the surviving stretches only.
    func reanalyseFromDisk(_ session: Session) {
        let directory = PersistenceContainer.documentsSessionsDirectory()
            .appendingPathComponent(session.rawSampleDirectory)
        guard let raw = try? RawSampleFileStore.read(startDate: session.startDate, from: directory) else { return }
        reanalyse(session, from: raw)
        try? modelContext.save()
    }

    /// Recomputes one session in place from its raw samples.
    private func reanalyse(_ session: Session, from raw: RawSessionData) {
        let settings = athlete.settings!
        let result = SessionAnalyzer.analyze(
            session: raw,
            settings: AnalysisSettings(
                hrThresholdLow: settings.hrThresholdLow,
                hrThresholdHigh: settings.hrThresholdHigh,
                mechZonePercentLow: settings.mechZonePercentLow,
                mechZonePercentHigh: settings.mechZonePercentHigh,
                confirmedMech45sAnchor: settings.confirmedMech45sAnchor
            ),
            isConditioning: session.isConditioning
        )

        session.hrZoneI1Seconds = result.hrZoneSeconds[.i1] ?? 0
        session.hrZoneI2Seconds = result.hrZoneSeconds[.i2] ?? 0
        session.hrZoneI3Seconds = result.hrZoneSeconds[.i3] ?? 0
        session.mechZone1Seconds = result.mechZoneSeconds[.zone1] ?? 0
        session.mechZone2Seconds = result.mechZoneSeconds[.zone2] ?? 0
        session.mechZone3Seconds = result.mechZoneSeconds[.zone3] ?? 0
        session.mechZoneAnchorUsed = result.mechZoneAnchorUsed
        session.secondsAboveAnchor = result.secondsAboveAnchor
        session.bestNineSecondsSignal = result.bestNineSecondsSignal
        session.bestNineSecondsRateHz = result.bestNineSecondsRateHz
        session.excludedWalkingSeconds = result.excludedWalkingSeconds
        session.inactiveSeconds = result.inactiveSeconds
        session.analysisVersion = AnalysisGeneration.current

        try? sessionRepository.replaceCurvePoints(for: session, curve: result.curve, in: modelContext)
        syncSessionInBackground(session)
    }

    /// Re-reads every stored session against the current settings.
    ///
    /// Called when the *percentages* move, because those define the zones and
    /// the definition has to be the same across the history to compare two
    /// weeks. Deliberately **not** called when the 45 s reference moves: that
    /// one measures the athlete, and recomputing on it would turn a hard
    /// session from six months ago into an easy one the day they get stronger.
    /// Each session carries the reference it was read with in
    /// `mechZoneAnchorUsed`. Settings offers this explicitly for the one case
    /// that does justify rewriting the past — a reference that was wrong.
    func recomputeStoredSessions() {
        guard let sessions = try? allSessions() else { return }
        for session in sessions {
            let directory = PersistenceContainer.documentsSessionsDirectory()
                .appendingPathComponent(session.rawSampleDirectory)
            guard let raw = try? RawSampleFileStore.read(startDate: session.startDate, from: directory) else { continue }
            reanalyse(session, from: raw)
        }
        try? modelContext.save()
    }

    func confirmMechanicalZoneUpdate(newAnchor: Double, sessionID: UUID) throws {
        let settings = athlete.settings!
        settings.confirmedMech45sAnchor = newAnchor
        settings.confirmedMech45sAnchorDate = .now
        settings.confirmedMech45sAnchorSessionID = sessionID
        try modelContext.save()
    }

    /// A session in the history whose 45 s peak beats the confirmed reference.
    ///
    /// The app offers a new reference at import and never again, so a proposal
    /// declined or missed that day is gone: the athlete keeps a reference lower
    /// than something they have already done, and every zone reads a notch too
    /// hard for the rest of time. This is what surfaces it afterwards.
    var recordBeyondConfirmedAnchor: (session: Session, peak: Double)? {
        guard let settings = athlete.settings else { return nil }
        let best = (try? allSessions())?
            .compactMap { session -> (Session, Double)? in
                guard !session.isConditioning else { return nil }
                guard let peak = session.curvePoints
                    .first(where: { $0.windowSeconds == 45 })?.peakValue else { return nil }
                return (session, peak)
            }
            .max(by: { $0.1 < $1.1 })
        guard let best, best.1 > settings.confirmedMech45sAnchor + 0.001 else { return nil }
        return best
    }

    /// Pulls the fatigue thresholds the coach set for this athlete.
    ///
    /// **The coach owns them.** They are stored in a document the phone never
    /// writes, so this is a one-way read and there is nothing to reconcile —
    /// which is the whole point: without it the athlete's screen and the
    /// coach's could show different verdicts on the same test, and neither
    /// would be wrong from where it stood.
    ///
    /// Silent on failure. A coach who has set nothing, an athlete offline in a
    /// changing room — both leave the defaults standing, which is the right
    /// answer, not an error worth a banner.
    func refreshHRVThresholds() async {
        guard let settings = athlete.settings else { return }
        guard let coachValues = try? await syncService.fetchHRVThresholds(
            athleteId: athlete.id.uuidString), !coachValues.isEmpty
        else { return }

        // Each is applied only if the coach actually set it, so a partial
        // document leaves the rest at their defaults rather than at zero.
        func apply(_ key: String, _ assign: (Double) -> Void) {
            if let value = coachValues[key] { assign(value) }
        }
        apply("energyCollapseHFSupine") { settings.hrvEnergyCollapseHFSupine = $0 }
        apply("energyCollapseLFStanding") { settings.hrvEnergyCollapseLFStanding = $0 }
        apply("acuteStressLFSupine") { settings.hrvAcuteStressLFSupine = $0 }
        apply("acuteStressLFStanding") { settings.hrvAcuteStressLFStanding = $0 }
        apply("activationBrakeHFSupine") { settings.hrvActivationBrakeHFSupine = $0 }
        apply("activationBrakeHFStanding") { settings.hrvActivationBrakeHFStanding = $0 }
        apply("extremeFatigueHFSupine") { settings.hrvExtremeFatigueHFSupine = $0 }
        apply("peripheralRegulationLFStanding") { settings.hrvPeripheralRegulationLFStanding = $0 }
        apply("smallBasePower") { settings.hrvSmallBasePower = $0 }
        try? modelContext.save()
    }

    /// Sends a morning test to the coach. Best-effort like the session push:
    /// the measurement is already safe on the phone whatever the network does.
    func syncHRVTestInBackground(_ test: HRVTest) {
        guard let supine = HeartRateVariability.analyse(rrIntervalsMs: test.supineRRms.map(Double.init)),
              let standing = HeartRateVariability.analyse(rrIntervalsMs: test.standingRRms.map(Double.init))
        else { return }

        let payload = HRVTestSyncPayload(
            id: test.id.uuidString,
            athleteId: athlete.id.uuidString,
            date: test.date,
            supineMeanHR: supine.meanHRbpm,
            supineRMSSD: supine.rmssdMs,
            supineTotalPower: supine.totalPower,
            supineLFOverHF: supine.lfOverHf,
            supineLF: supine.lf,
            supineHF: supine.hf,
            standingMeanHR: standing.meanHRbpm,
            standingRMSSD: standing.rmssdMs,
            standingTotalPower: standing.totalPower,
            standingLFOverHF: standing.lfOverHf,
            standingLF: standing.lf,
            standingHF: standing.hf,
            wellnessScore: test.wellnessScore,
            isReliable: supine.isFrequencyDomainReliable && standing.isFrequencyDomainReliable
        )
        Task { await pushInBackground { try await self.syncService.pushHRVTest(payload) } }
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
