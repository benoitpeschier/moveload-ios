import Foundation
import SwiftData
import MoveLoadCore

public struct SessionRepository {
    public init() {}

    @discardableResult
    public func createSession(
        id: UUID = UUID(),
        from raw: RawSessionData,
        analysis: SessionAnalysisResult,
        athlete: Athlete,
        logbookEntryID: String,
        rawSampleDirectory: String,
        in context: ModelContext
    ) throws -> Session {
        let session = Session(
            id: id,
            athlete: athlete,
            startDate: raw.startDate,
            endDate: raw.startDate.addingTimeInterval(raw.duration),
            status: .analyzed,
            sensorLogbookEntryID: logbookEntryID,
            rawSampleDirectory: rawSampleDirectory
        )
        session.hrZoneI1Seconds = analysis.hrZoneSeconds[.i1] ?? 0
        session.hrZoneI2Seconds = analysis.hrZoneSeconds[.i2] ?? 0
        session.hrZoneI3Seconds = analysis.hrZoneSeconds[.i3] ?? 0
        session.mechZone1Seconds = analysis.mechZoneSeconds[.zone1] ?? 0
        session.mechZone2Seconds = analysis.mechZoneSeconds[.zone2] ?? 0
        session.mechZone3Seconds = analysis.mechZoneSeconds[.zone3] ?? 0
        session.mechZoneAnchorUsed = analysis.mechZoneAnchorUsed
        session.excludedWalkingSeconds = analysis.excludedWalkingSeconds
        session.inactiveSeconds = analysis.inactiveSeconds
        session.analysisVersion = AnalysisGeneration.current

        context.insert(session)

        for window in MechanicalWindow.allCases {
            let point = MechanicalCurvePoint(windowSeconds: window.seconds, peakValue: analysis.curve[window] ?? nil, session: session)
            context.insert(point)
        }

        try context.save()
        return session
    }

    /// Replaces a session's curve points wholesale — used when the app's
    /// mechanical window set changes and an already-analyzed session's stored
    /// points no longer match `MechanicalWindow.allCases` (see AppEnvironment's
    /// startup migration, which recomputes `curve` from the still-on-disk raw
    /// accel data before calling this).
    public func replaceCurvePoints(for session: Session, curve: [MechanicalWindow: Double?], in context: ModelContext) throws {
        for point in session.curvePoints {
            context.delete(point)
        }
        session.curvePoints = []
        for window in MechanicalWindow.allCases {
            let point = MechanicalCurvePoint(windowSeconds: window.seconds, peakValue: curve[window] ?? nil, session: session)
            context.insert(point)
        }
        try context.save()
    }

    /// The session already imported from a given sensor recording, if any.
    ///
    /// Importing has to be idempotent — a recording stays on the sensor after
    /// import and the recovery path re-walks ids from the start — but the
    /// logbook id alone cannot identify it. That id is a slot in the sensor's
    /// memory and the counter restarts at 1 whenever the logbook is erased, so
    /// matching on it alone made every recording made after an erase look like
    /// one already imported, and the athlete's history silently stopped
    /// growing. The start date settles it: two recordings cannot begin at the
    /// same instant.
    public func session(
        withLogbookEntryID id: String,
        startDate: Date,
        in context: ModelContext
    ) throws -> Session? {
        guard !id.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sensorLogbookEntryID == id }
        )
        // Tolerance rather than equality: a re-download re-derives the date
        // from the file, and rounding must not defeat the match.
        return try context.fetch(descriptor).first {
            abs($0.startDate.timeIntervalSince(startDate)) < 2
        }
    }

    public func allSessions(in context: ModelContext) throws -> [Session] {
        let descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        return try context.fetch(descriptor)
    }

    /// Flattened (window, peak) pairs across sessions since `cutoffDate`, for
    /// AnalysisEngine.RecordCalculator.liveRecords to reduce — kept as plain
    /// tuples here so PersistenceKit doesn't need to depend on AnalysisEngine.
    public func historicalPeaks(after cutoffDate: Date, in context: ModelContext) throws -> [(window: MechanicalWindow, value: Double)] {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.startDate >= cutoffDate })
        let sessions = try context.fetch(descriptor)
        return sessions.flatMap { session in
            session.curvePoints.compactMap { point -> (window: MechanicalWindow, value: Double)? in
                guard let value = point.peakValue, let window = point.window else { return nil }
                return (window, value)
            }
        }
    }
}
