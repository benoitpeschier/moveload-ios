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

    /// The window the signal is averaged over before being classified.
    ///
    /// 15 s, and it is not a free parameter: a shorter one lets the gap
    /// between two strokes drag the level down, a longer one averages a hard
    /// repetition together with the rest that follows it. Measured on a
    /// session of 23 repetitions of ~24 s with 88 s recovery, a 30 s window
    /// never once reached the athlete's anchor (89 % of it at best) while 15 s
    /// reached 112 %, and zone 3 lost a quarter of its time. On long steady
    /// blocks the two agree exactly, so the short window costs nothing.
    ///
    /// **Fixed once and never changed**: unlike the thresholds, which can be
    /// re-applied to stored figures, changing this makes every past session
    /// incomparable with every future one.
    public static let mechZoneWindowSeconds: Double = 15

    /// Time in each mechanical zone, classifying a **rolling mean** of the
    /// effort signal rather than each sample on its own.
    ///
    /// Classifying raw samples cannot produce three zones, and no choice of
    /// thresholds fixes it. The instantaneous signal is a spike at zero — the
    /// glide between strokes — plus a smooth decaying tail, so a middle band
    /// is crossed on the way up and down and never occupied: measured across
    /// four sessions it held 3.9, 4.0, 4.6 and 5.2 % of the time whatever the
    /// session contained, because that figure tracks the band's *width*, not
    /// the athlete's effort. Averaging first gives the signal something to
    /// dwell in.
    ///
    /// `keepMask`, when supplied, drops excluded samples (walking to and from
    /// the water) so zone time reflects time actually spent paddling. The mean
    /// is taken over kept samples only, so a walk in the middle of a session
    /// does not drag the level down around it.
    public static func mechZoneSeconds(
        accelX: [Double],
        sampleRateHz: Double,
        thresholdLow: Double,
        thresholdHigh: Double,
        keepMask: [Bool]? = nil,
        windowSeconds: Double = mechZoneWindowSeconds
    ) -> [MechZone: TimeInterval] {
        var seconds: [MechZone: TimeInterval] = [.zone1: 0, .zone2: 0, .zone3: 0]
        guard !accelX.isEmpty, sampleRateHz > 0 else { return seconds }

        let dt = 1.0 / sampleRateHz
        let mask = keepMask?.count == accelX.count ? keepMask : nil
        let window = max(1, Int((windowSeconds * sampleRateHz).rounded()))

        // Running sum over kept samples: the divisor counts how many of the
        // window's samples were kept, so excluded stretches neither contribute
        // nor dilute.
        var sum = 0.0
        var kept = 0
        var head = 0

        for index in accelX.indices {
            while head < accelX.count && head < index + window / 2 + 1 {
                if mask?[head] ?? true {
                    sum += max(0, accelX[head]); kept += 1
                }
                head += 1
            }
            let tail = index - (window - window / 2)
            if tail >= 0, mask?[tail] ?? true {
                sum -= max(0, accelX[tail]); kept -= 1
            }

            guard mask?[index] ?? true, kept > 0 else { continue }
            seconds[mechZone(for: sum / Double(kept), low: thresholdLow, high: thresholdHigh), default: 0] += dt
        }
        return seconds
    }

    /// Seconds spent above the athlete's anchor, on the **instantaneous**
    /// signal.
    ///
    /// The one figure no rolling mean can give: real seconds of hard work,
    /// depending on no window at all. Zones say how the load was spread;
    /// this says how much of it was hard.
    public static func secondsAboveAnchor(
        accelX: [Double],
        sampleRateHz: Double,
        anchor: Double,
        keepMask: [Bool]? = nil
    ) -> TimeInterval {
        guard anchor > 0, sampleRateHz > 0 else { return 0 }
        let dt = 1.0 / sampleRateHz
        let mask = keepMask?.count == accelX.count ? keepMask : nil
        var total: TimeInterval = 0
        for (index, raw) in accelX.enumerated() {
            if let mask, !mask[index] { continue }
            if max(0, raw) > anchor { total += dt }
        }
        return total
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
