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

    public init(
        hrZoneSeconds: [HRZone: TimeInterval],
        mechZoneSeconds: [MechZone: TimeInterval],
        curve: [MechanicalWindow: Double?],
        mechZoneAnchorUsed: Double
    ) {
        self.hrZoneSeconds = hrZoneSeconds
        self.mechZoneSeconds = mechZoneSeconds
        self.curve = curve
        self.mechZoneAnchorUsed = mechZoneAnchorUsed
    }

    public var peak45s: Double? {
        curve[.s45] ?? nil
    }
}
