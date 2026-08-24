import Foundation
import SwiftData
import MoveLoadCore

public enum HistoryUnit: String, Codable, Sendable, CaseIterable, Hashable {
    case days, weeks, months
}

public enum SessionStatus: String, Codable, Sendable {
    case recording, downloaded, analyzed, failed
}

public enum Gender: String, Codable, Sendable, CaseIterable, Hashable {
    case male, female
}

/// Generations of the analysis, so stored results can be recognised as stale.
public enum AnalysisGeneration {
    /// Load computed from the raw axis, which included gravity — a motionless
    /// sensor could outscore real paddling.
    public static let rawAxis = 0
    /// Load computed from the axis with its slow (gravity and posture)
    /// component removed.
    public static let gravityRemoved = 1
    /// Zone time stops counting effortless stretches — conveyor rides, rest,
    /// waiting — which previously piled into zone 1.
    public static let inactivityExcluded = 2
    /// Mechanical zones read off a 15 s rolling mean instead of each sample on
    /// its own, with thresholds moved from 70/90 % of the anchor to 35/55 %.
    /// Every stored zone time from before this is on a different scale and
    /// cannot be compared with anything after it.
    public static let rollingMeanZones = 3

    public static let current = rollingMeanZones
}

/// Boat class the session was recorded in — used to compare an athlete's
/// records against peers in the same gender/boat category (coach webapp).
public enum BoatType: String, Codable, Sendable, CaseIterable, Hashable {
    case k1 = "K1", c1 = "C1", kx = "KX"
}

@Model
public final class Athlete {
    public var id: UUID = UUID()
    public var name: String?
    public var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade) public var settings: AthleteSettings?

    public init(id: UUID = UUID(), name: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

@Model
public final class AthleteSettings {
    public var hrThresholdLow: Double = 130
    public var hrThresholdHigh: Double = 160
    /// Zone boundaries as a share of the confirmed 45 s anchor.
    ///
    /// 35 % and 55 %, not 70/90: the zones are read off a 15 s rolling mean,
    /// which lives at 26–44 % of the anchor in median and reaches 62–88 % at
    /// its 90th centile. Thresholds at 70/90 sat above almost everything a
    /// session reaches — zone 3 meant "within 10 % of your lifetime best
    /// 45 s". Those figures were right for the instantaneous signal, whose
    /// spikes tower over its own mean, and wrong once the signal is averaged.
    public var mechZonePercentLow: Double = 0.35
    public var mechZonePercentHigh: Double = 0.55
    public var recordsHistoryValue: Int = 90
    public var recordsHistoryUnitRaw: String = HistoryUnit.days.rawValue
    /// The athlete-confirmed 45s anchor mechanical zones are derived from — distinct
    /// from the "live" record computed on demand from session history (see
    /// AnalysisEngine.RecordCalculator). Only updated when the athlete explicitly
    /// confirms a new record after a session.
    public var confirmedMech45sAnchor: Double = 0
    public var confirmedMech45sAnchorDate: Date?
    public var confirmedMech45sAnchorSessionID: UUID?
    /// Used to compare the athlete's records against peers of the same gender
    /// and boat class in the coach webapp — not used by any on-device analysis.
    public var genderRaw: String = Gender.male.rawValue
    /// The one sensor this athlete's app will talk to, chosen once from the
    /// sensors in range. Empty until then. Without it the app connects to
    /// whichever sensor answers first, which in a clubhouse means somebody
    /// else's.
    public var pairedSensorSerial: String = ""

    public var recordsHistoryUnit: HistoryUnit {
        get { HistoryUnit(rawValue: recordsHistoryUnitRaw) ?? .days }
        set { recordsHistoryUnitRaw = newValue.rawValue }
    }

    public var gender: Gender {
        get { Gender(rawValue: genderRaw) ?? .male }
        set { genderRaw = newValue.rawValue }
    }

    public init(
        hrThresholdLow: Double = 130,
        hrThresholdHigh: Double = 160,
        mechZonePercentLow: Double = 0.35,
        mechZonePercentHigh: Double = 0.55,
        recordsHistoryValue: Int = 90,
        recordsHistoryUnit: HistoryUnit = .days,
        confirmedMech45sAnchor: Double = 0,
        confirmedMech45sAnchorDate: Date? = nil,
        confirmedMech45sAnchorSessionID: UUID? = nil,
        gender: Gender = .male
    ) {
        self.hrThresholdLow = hrThresholdLow
        self.hrThresholdHigh = hrThresholdHigh
        self.mechZonePercentLow = mechZonePercentLow
        self.mechZonePercentHigh = mechZonePercentHigh
        self.recordsHistoryValue = recordsHistoryValue
        self.recordsHistoryUnitRaw = recordsHistoryUnit.rawValue
        self.confirmedMech45sAnchor = confirmedMech45sAnchor
        self.confirmedMech45sAnchorDate = confirmedMech45sAnchorDate
        self.confirmedMech45sAnchorSessionID = confirmedMech45sAnchorSessionID
        self.genderRaw = gender.rawValue
    }
}

@Model
public final class Session {
    public var id: UUID = UUID()
    public var athlete: Athlete?
    public var startDate: Date = Date.now
    public var endDate: Date = Date.now
    public var statusRaw: String = SessionStatus.downloaded.rawValue
    public var sensorLogbookEntryID: String = ""
    /// Serial of the sensor this recording came from. Empty for sessions
    /// imported before it was recorded, and for the Showcase JSON path, which
    /// carries no serial — so an empty value means "unknown", never "mine".
    ///
    /// Kept because the logbook id says nothing about *which* sensor: in a
    /// changing room full of them a session downloaded from the wrong one
    /// would otherwise be indistinguishable from a real one, for good.
    public var sensorSerial: String = ""
    public var rawSampleDirectory: String = ""

    public var hrZoneI1Seconds: Double = 0
    public var hrZoneI2Seconds: Double = 0
    public var hrZoneI3Seconds: Double = 0
    public var mechZone1Seconds: Double = 0
    public var mechZone2Seconds: Double = 0
    public var mechZone3Seconds: Double = 0
    /// Snapshot of the anchor at analysis time — if the athlete later confirms a
    /// new anchor, this past session's zone-time reading doesn't silently drift.
    public var mechZoneAnchorUsed: Double = 0

    /// Time automatically left out of the load analysis as walking rather than
    /// paddling (see GaitDetector). Persisted so the exclusion stays visible
    /// after the fact — it happens silently, and an athlete comparing two
    /// sessions deserves to see that one had 9 minutes removed.
    /// Seconds above the athlete's anchor, from the instantaneous signal —
    /// the hard-work figure the rolling-mean zones cannot express.
    public var secondsAboveAnchor: Double = 0
    public var excludedWalkingSeconds: Double = 0

    /// Which generation of the analysis produced this session's numbers, so a
    /// change in what the metric means can recompute past sessions instead of
    /// leaving a history where old and new values are silently incomparable.
    /// 0 = before the load axis had gravity removed. See `AnalysisGeneration`.
    public var analysisVersion: Int = 0

    /// Time left out of zone time as effortless — conveyor rides back up the
    /// course, rest, waiting. Kept in the peak curve, so this explains why the
    /// zone totals fall short of the session's duration.
    public var inactiveSeconds: Double = 0

    /// Athlete-reported RPE (rate of perceived exertion), 1 (facile) to 10
    /// (extrêmement difficile). Nil until the athlete sets it from the session
    /// detail screen — distinct from the objective cardio/mechanical load.
    public var perceivedExertion: Int?

    /// Boat class for this session (K1/C1/KX). Nil until the athlete sets it —
    /// distinct sessions can be in different boats.
    public var boatTypeRaw: String?

    public var boatType: BoatType? {
        get { boatTypeRaw.flatMap { BoatType(rawValue: $0) } }
        set { boatTypeRaw = newValue?.rawValue }
    }

    /// Flags a session recorded under standardized test conditions (as opposed
    /// to regular training) — lets records/comparisons be isolated to
    /// comparable-effort sessions later, rather than mixing test and training data.
    public var isTest: Bool = false

    /// Optional athlete-given label ("Test 45s", "Fractionné 8x2min"). Nil or
    /// empty means the session is identified by its date, as before.
    public var name: String?

    /// What to show for this session: its name when it has one, its date
    /// otherwise.
    public var displayTitle: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? startDate.formatted(date: .abbreviated, time: .shortened)
            : trimmed
    }

    @Relationship(deleteRule: .cascade, inverse: \MechanicalCurvePoint.session)
    public var curvePoints: [MechanicalCurvePoint] = []

    public var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    public var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    public init(
        id: UUID = UUID(),
        athlete: Athlete? = nil,
        startDate: Date,
        endDate: Date,
        status: SessionStatus = .downloaded,
        sensorLogbookEntryID: String,
        sensorSerial: String = "",
        rawSampleDirectory: String
    ) {
        self.id = id
        self.athlete = athlete
        self.startDate = startDate
        self.endDate = endDate
        self.statusRaw = status.rawValue
        self.sensorLogbookEntryID = sensorLogbookEntryID
        self.sensorSerial = sensorSerial
        self.rawSampleDirectory = rawSampleDirectory
    }
}

@Model
public final class MechanicalCurvePoint {
    public var windowSeconds: Double = 0
    public var peakValue: Double?
    public var session: Session?

    public init(windowSeconds: Double, peakValue: Double?, session: Session? = nil) {
        self.windowSeconds = windowSeconds
        self.peakValue = peakValue
        self.session = session
    }

    public var window: MechanicalWindow? {
        MechanicalWindow.allCases.first { $0.seconds == windowSeconds }
    }
}
