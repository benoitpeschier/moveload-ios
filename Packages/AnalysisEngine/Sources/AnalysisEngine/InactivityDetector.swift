import Foundation
import MoveLoadCore

/// Finds the stretches where the athlete produced no meaningful effort —
/// riding a conveyor back up the course, resting against the stern, waiting
/// between runs.
///
/// Used for zone time only. Those stretches otherwise pile into zone 1 and
/// describe a session as far easier and longer than it was: on a real slalom
/// session (2026-08-19) they came to 36% of the recording. The peak curve is
/// deliberately left alone — motionless time never wins a peak anyway, and
/// cutting the recording further would fragment it so much that the long
/// windows could rarely be measured at all.
///
/// Why amplitude rather than rhythm: telling a conveyor ride from a rest was
/// tried and abandoned. A conveyor carries you at constant velocity, which an
/// accelerometer cannot see at all, and the backward lean it produces is the
/// same posture as resting on the boat. Stroke rhythmicity turned out not to
/// separate either (0.70 against 0.60 — total overlap). Effort amplitude does:
/// clearly quiet windows reached 0.14 at their 95th centile, clearly active
/// ones started at 0.64, an empty band between the two.
///
/// The threshold is a fraction of the session's own active level rather than a
/// fixed value in m/s², so it does not depend on how the sensor is strapped on
/// or how hard this particular athlete paddles.
public enum InactivityDetector {
    public static let windowSeconds: Double = 8.0
    public static let hopSeconds: Double = 4.0
    /// Reference for "what this session's real effort looks like". A high
    /// centile rather than the median, which the inactive time itself drags
    /// down.
    public static let referenceCentile: Double = 0.90
    /// Fraction of that reference below which a window counts as inactive.
    /// Lands mid-gap on the measured separation.
    public static let inactiveFraction: Double = 0.30
    /// Runs shorter than this are ignored: the pause between two strokes is
    /// not a rest, and nibbling at them would quietly shorten every session.
    public static let minimumRunSeconds: Double = 20.0

    public struct Result: Sendable {
        /// One flag per sample: true = count this sample's time.
        public let activeMask: [Bool]
        public let inactiveSeconds: TimeInterval
    }

    /// `excluded` marks samples already dropped for another reason (walking),
    /// which are neither counted here nor allowed to skew the reference level.
    public static func detect(
        effort: [Double],
        sampleRateHz: Double,
        excluded: [Bool]? = nil
    ) -> Result {
        let count = effort.count
        guard count > 0, sampleRateHz > 0 else {
            return Result(activeMask: [Bool](repeating: true, count: count), inactiveSeconds: 0)
        }
        let windowSize = Int((windowSeconds * sampleRateHz).rounded())
        let hop = max(1, Int((hopSeconds * sampleRateHz).rounded()))
        guard windowSize > 1, count >= windowSize else {
            return Result(activeMask: [Bool](repeating: true, count: count), inactiveSeconds: 0)
        }

        // Mean positive effort per window, skipping windows that are mostly
        // already excluded.
        var windows: [(range: Range<Int>, level: Double)] = []
        var start = 0
        while start + windowSize <= count {
            let range = start..<(start + windowSize)
            if let excluded, excluded.count == count {
                let droppedCount = range.reduce(into: 0) { $0 += excluded[$1] ? 0 : 1 }
                if droppedCount > windowSize / 2 { start += hop; continue }
            }
            let level = range.reduce(0.0) { $0 + Swift.max(0, effort[$1]) } / Double(windowSize)
            windows.append((range, level))
            start += hop
        }
        guard windows.count >= 4 else {
            return Result(activeMask: [Bool](repeating: true, count: count), inactiveSeconds: 0)
        }

        let levels = windows.map(\.level).sorted()
        let reference = levels[Swift.min(levels.count - 1, Int(Double(levels.count) * referenceCentile))]
        let threshold = reference * inactiveFraction
        // A session with no real effort at all has no meaningful reference;
        // calling all of it inactive would be worse than calling none of it.
        guard reference > 0 else {
            return Result(activeMask: [Bool](repeating: true, count: count), inactiveSeconds: 0)
        }

        var votes = [Double](repeating: 0, count: count)
        var voteCounts = [Double](repeating: 0, count: count)
        for window in windows {
            let inactive = window.level < threshold ? 1.0 : 0.0
            for i in window.range {
                votes[i] += inactive
                voteCounts[i] += 1
            }
        }

        var inactive = (0..<count).map { voteCounts[$0] > 0 && votes[$0] / voteCounts[$0] >= 0.5 }
        enforceMinimumRun(&inactive, minSamples: Int((minimumRunSeconds * sampleRateHz).rounded()))

        let inactiveCount = inactive.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        return Result(
            activeMask: inactive.map { !$0 },
            inactiveSeconds: Double(inactiveCount) / sampleRateHz
        )
    }

    private static func enforceMinimumRun(_ mask: inout [Bool], minSamples: Int) {
        guard minSamples > 1, !mask.isEmpty else { return }
        var runStart: Int?
        for i in 0...mask.count {
            let isInactive = i < mask.count && mask[i]
            if isInactive, runStart == nil {
                runStart = i
            } else if !isInactive, let s = runStart {
                if i - s < minSamples {
                    for j in s..<i { mask[j] = false }
                }
                runStart = nil
            }
        }
    }
}
