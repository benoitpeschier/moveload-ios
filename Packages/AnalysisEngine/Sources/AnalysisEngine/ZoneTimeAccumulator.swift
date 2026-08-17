import Foundation
import MoveLoadCore

public enum ZoneTimeAccumulator {
    /// `keptRanges`, when supplied, restricts the count to the stretches of the
    /// session kept for analysis (walking excluded) so that cardio and
    /// mechanical zone times cover the same span and can be read side by side.
    /// Ranges must be sorted and non-overlapping, as `GaitDetector` produces them.
    public static func hrZoneSeconds(
        hrSamples: [HRSample],
        sessionDuration: TimeInterval,
        thresholdLow: Double,
        thresholdHigh: Double,
        keptRanges: [Range<TimeInterval>]? = nil
    ) -> [HRZone: TimeInterval] {
        var seconds: [HRZone: TimeInterval] = [.i1: 0, .i2: 0, .i3: 0]
        guard !hrSamples.isEmpty else { return seconds }

        let sorted = hrSamples.sorted { $0.timeOffset < $1.timeOffset }
        for (index, sample) in sorted.enumerated() {
            let nextOffset = index + 1 < sorted.count ? sorted[index + 1].timeOffset : sessionDuration
            let dt = keptDuration(from: sample.timeOffset, to: nextOffset, ranges: keptRanges)
            seconds[hrZone(for: sample.bpm, low: thresholdLow, high: thresholdHigh), default: 0] += dt
        }
        return seconds
    }

    /// How much of `from..<to` falls inside the kept ranges.
    private static func keptDuration(
        from: TimeInterval,
        to: TimeInterval,
        ranges: [Range<TimeInterval>]?
    ) -> TimeInterval {
        guard let ranges else { return max(0, to - from) }
        var total: TimeInterval = 0
        for range in ranges {
            let lower = max(from, range.lowerBound)
            let upper = min(to, range.upperBound)
            if upper > lower { total += upper - lower }
        }
        return total
    }

    /// Classifies the raw (positive-clamped) acceleration signal directly against
    /// the zone thresholds — not a rolling average. A brief burst above the
    /// zone 3 threshold counts immediately, even if it only lasts one sample;
    /// this is deliberately different from the 6-window curve's rolling-mean
    /// peaks, which smooth over their window and can't be compared the same way.
    /// `keepMask`, when supplied, drops excluded samples (walking to and from
    /// the water) so zone time reflects time actually spent paddling.
    public static func mechZoneSeconds(
        accelX: [Double],
        sampleRateHz: Double,
        thresholdLow: Double,
        thresholdHigh: Double,
        keepMask: [Bool]? = nil
    ) -> [MechZone: TimeInterval] {
        var seconds: [MechZone: TimeInterval] = [.zone1: 0, .zone2: 0, .zone3: 0]
        let dt = 1.0 / sampleRateHz
        let mask = keepMask?.count == accelX.count ? keepMask : nil
        for (index, raw) in accelX.enumerated() {
            if let mask, !mask[index] { continue }
            let value = max(0, raw)
            seconds[mechZone(for: value, low: thresholdLow, high: thresholdHigh), default: 0] += dt
        }
        return seconds
    }

    private static func hrZone(for bpm: Double, low: Double, high: Double) -> HRZone {
        if bpm < low { return .i1 }
        if bpm < high { return .i2 }
        return .i3
    }

    private static func mechZone(for value: Double, low: Double, high: Double) -> MechZone {
        if value < low { return .zone1 }
        if value < high { return .zone2 }
        return .zone3
    }
}
