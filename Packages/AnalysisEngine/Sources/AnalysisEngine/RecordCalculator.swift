import Foundation
import MoveLoadCore

public enum RecordCalculator {
    public struct HistoricalPeak: Sendable {
        public let window: MechanicalWindow
        public let value: Double

        public init(window: MechanicalWindow, value: Double) {
            self.window = window
            self.value = value
        }
    }

    /// Reduces a flattened list of past sessions' curve points (already filtered
    /// to the configured history window by the caller) to the best value per window.
    public static func liveRecords(from peaks: [HistoricalPeak]) -> [MechanicalWindow: Double] {
        var result: [MechanicalWindow: Double] = [:]
        for peak in peaks {
            result[peak.window] = max(result[peak.window] ?? -.infinity, peak.value)
        }
        return result
    }
}
