import Foundation

/// Immutable snapshot of the settings AnalysisEngine needs, so it never depends on SwiftData.
public struct AnalysisSettings: Sendable {
    public let hrThresholdLow: Double
    public let hrThresholdHigh: Double
    public let mechZonePercentLow: Double
    public let mechZonePercentHigh: Double
    public let confirmedMech45sAnchor: Double

    public init(
        hrThresholdLow: Double,
        hrThresholdHigh: Double,
        mechZonePercentLow: Double,
        mechZonePercentHigh: Double,
        confirmedMech45sAnchor: Double
    ) {
        self.hrThresholdLow = hrThresholdLow
        self.hrThresholdHigh = hrThresholdHigh
        self.mechZonePercentLow = mechZonePercentLow
        self.mechZonePercentHigh = mechZonePercentHigh
        self.confirmedMech45sAnchor = confirmedMech45sAnchor
    }
}

public struct SessionAnalysisResult: Sendable {
    public let hrZoneSeconds: [HRZone: TimeInterval]
    public let mechZoneSeconds: [MechZone: TimeInterval]
    public let curve: [MechanicalWindow: Double?]
    public let mechZoneAnchorUsed: Double
    /// Time dropped as walking rather than paddling. Zero when the session
    /// carried no triaxial data to judge from.
    public let excludedWalkingSeconds: TimeInterval
    /// Time spent producing no effort — conveyor rides, rest, waiting — left
    /// out of zone time but kept in the peak curve. See InactivityDetector.
    public let inactiveSeconds: TimeInterval
    /// Seconds above the athlete's anchor, on the instantaneous signal — real
    /// seconds of hard work, which the rolling-mean zones cannot express.
    public let secondsAboveAnchor: TimeInterval
    /// The effort signal over the athlete's best nine seconds, sample for
    /// sample. Every other figure here is a total or a peak; this is the only
    /// one that carries a *shape*, which is what a stroke is judged on — how
    /// the pull builds, where it peaks, how clean the recovery is. Empty when
    /// the session was too short to hold a nine-second window.
    public let bestNineSecondsSignal: [Double]
    /// Sample rate of `bestNineSecondsSignal`, so it can be plotted against
    /// time without assuming the session's rate elsewhere.
    public let bestNineSecondsRateHz: Double

    public init(
        hrZoneSeconds: [HRZone: TimeInterval],
        mechZoneSeconds: [MechZone: TimeInterval],
        curve: [MechanicalWindow: Double?],
        mechZoneAnchorUsed: Double,
        excludedWalkingSeconds: TimeInterval = 0,
        inactiveSeconds: TimeInterval = 0,
        bestNineSecondsSignal: [Double] = [],
        bestNineSecondsRateHz: Double = 0,
        // Deliberately no default: this was computed and then dropped from the
        // call for a whole build, and a default of zero made it compile
        // silently and read as "no hard work" rather than as a mistake.
        secondsAboveAnchor: TimeInterval
    ) {
        self.hrZoneSeconds = hrZoneSeconds
        self.mechZoneSeconds = mechZoneSeconds
        self.curve = curve
        self.secondsAboveAnchor = secondsAboveAnchor
        self.mechZoneAnchorUsed = mechZoneAnchorUsed
        self.excludedWalkingSeconds = excludedWalkingSeconds
        self.inactiveSeconds = inactiveSeconds
        self.bestNineSecondsSignal = bestNineSecondsSignal
        self.bestNineSecondsRateHz = bestNineSecondsRateHz
    }

    public var peak45s: Double? {
        curve[.s45] ?? nil
    }
}
