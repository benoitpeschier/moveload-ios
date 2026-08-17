import Foundation
import MoveLoadCore

/// Finds the stretches of a session spent walking rather than paddling, so
/// they can be left out of the mechanical load analysis.
///
/// Why this is needed: walking to and from the water dominated the peak
/// curve on a real recording (2026-08-16) — the 6 s to 45 s peaks came out
/// roughly twice as high with it included, so the "records" were measuring
/// the athlete's walk, not their paddling.
///
/// How it tells them apart: walking bounces the trunk along gravity once per
/// step, rhythmically, at 1.2-3 Hz; paddling keeps the trunk vertically calm
/// and puts its motion into trunk rotation instead. Measured on that
/// recording, the vertical oscillation ran 2.28 m/s² (median) walking versus
/// 0.46 paddling — the threshold below sits in the empty gap between the two
/// distributions (paddling p95 0.65, walking p5 1.58).
///
/// Rather than reading a fixed axis, each window derives gravity from its own
/// mean acceleration vector and projects onto that, so the result does not
/// depend on how the sensor happens to be strapped on.
///
/// Calibrated against a single athlete and a single recording. The known
/// untested case is rough water, where waves could lift the boat vertically;
/// the step-band ratio guards against it by also demanding the bounce be
/// rhythmic, but that guard has not been confirmed on real chop.
public enum GaitDetector {
    public struct Result: Sendable {
        /// One flag per acceleration sample: true = keep for analysis.
        public let keepMask: [Bool]
        public let excludedSeconds: TimeInterval
    }

    public static let windowSeconds: Double = 4.0
    public static let hopSeconds: Double = 1.0
    /// Vertical oscillation (m/s², standard deviation) above which a window
    /// looks like walking.
    public static let verticalSDThreshold: Double = 1.2
    /// Share of vertical energy that must sit in the cadence band, so that
    /// non-rhythmic vertical movement (waves, a stumble) is not read as gait.
    public static let cadenceBandRatioThreshold: Double = 0.20
    /// Human walking cadence: roughly 90 to 130 steps per minute. This is a
    /// property of walking rather than a threshold fitted to our recordings,
    /// which is what makes it safe to lean on.
    public static let cadenceBand: ClosedRange<Double> = 1.5...2.2
    public static let analysisBand: ClosedRange<Double> = 0.3...6.0
    /// Runs shorter than this are absorbed into their neighbours. A real walk
    /// back up the bank lasts tens of seconds; a five-second "walk" in the
    /// middle of a session is far likelier to be a hard paddling stroke than a
    /// few steps, and wrongly dropping an effort costs more than keeping a few
    /// seconds of walking. Kept below ~25 s so genuinely short walks still
    /// register (the reference recording's first walk was 25 s).
    public static let minSegmentSeconds: Double = 15.0

    public static func detect(axes: AccelerationAxes, sampleRateHz: Double) -> Result {
        let count = axes.count
        let windowSize = Int((windowSeconds * sampleRateHz).rounded())
        let hop = max(1, Int((hopSeconds * sampleRateHz).rounded()))

        guard count > 0, sampleRateHz > 0 else {
            return Result(keepMask: [Bool](repeating: true, count: count), excludedSeconds: 0)
        }
        guard windowSize > 8, count >= windowSize else {
            // Too short to judge — keep everything rather than guess.
            return Result(keepMask: [Bool](repeating: true, count: count), excludedSeconds: 0)
        }

        // Overlapping windows vote per sample, which smooths the boundaries
        // instead of letting one window's verdict land as a hard edge.
        var votes = [Double](repeating: 0, count: count)
        var voteCounts = [Double](repeating: 0, count: count)

        var start = 0
        while start + windowSize <= count {
            let range = start..<(start + windowSize)
            let isGait = windowLooksLikeGait(axes: axes, range: range, sampleRateHz: sampleRateHz)
            for i in range {
                votes[i] += isGait ? 1 : 0
                voteCounts[i] += 1
            }
            start += hop
        }

        var walking = (0..<count).map { i in
            voteCounts[i] > 0 && (votes[i] / voteCounts[i]) >= 0.5
        }
        enforceMinimumRunLength(&walking, minSamples: Int((minSegmentSeconds * sampleRateHz).rounded()))

        let excluded = walking.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        return Result(
            keepMask: walking.map { !$0 },
            excludedSeconds: Double(excluded) / sampleRateHz
        )
    }

    /// The kept stretches as time ranges (seconds from session start), for
    /// callers working in time rather than sample indices — the heart-rate
    /// stream has its own irregular timeline and cannot use the sample mask
    /// directly.
    public static func keptTimeRanges(keepMask: [Bool], sampleRateHz: Double) -> [Range<TimeInterval>] {
        guard sampleRateHz > 0 else { return [] }
        var ranges: [Range<TimeInterval>] = []
        var start: Int?
        for i in 0...keepMask.count {
            let keep = i < keepMask.count && keepMask[i]
            if keep, start == nil {
                start = i
            } else if !keep, let s = start {
                ranges.append(Double(s) / sampleRateHz ..< Double(i) / sampleRateHz)
                start = nil
            }
        }
        return ranges
    }

    private static func windowLooksLikeGait(
        axes: AccelerationAxes,
        range: Range<Int>,
        sampleRateHz: Double
    ) -> Bool {
        let vertical = verticalComponent(axes: axes, range: range)
        let mean = vertical.reduce(0, +) / Double(vertical.count)
        let variance = vertical.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vertical.count)
        guard variance.squareRoot() >= verticalSDThreshold else { return false }

        let centred = vertical.map { $0 - mean }
        let spectrum = cadenceSpectrum(centred, sampleRateHz: sampleRateHz)
        guard spectrum.bandRatio >= cadenceBandRatioThreshold else { return false }
        // The bounce's *dominant* frequency has to be a walking cadence, not
        // merely have some energy in that band. Hard paddling at around 1 Hz
        // puts its second harmonic squarely in the cadence band, so a
        // band-energy test alone accepted it: on a real interval session
        // (2026-08-17) that wrongly excluded 11 minutes of the athlete's
        // hardest efforts — the most valuable part of the session — while the
        // genuine walks sat at a tight 1.77-1.94 Hz and the false positives at
        // 0.84-1.41 Hz.
        return cadenceBand.contains(spectrum.dominantFrequency)
    }

    /// Projection onto the window's own gravity direction, which is simply
    /// where the mean acceleration points once movement averages out.
    private static func verticalComponent(axes: AccelerationAxes, range: Range<Int>) -> [Double] {
        var sx = 0.0, sy = 0.0, sz = 0.0
        for i in range {
            sx += axes.x[i]
            sy += axes.y[i]
            sz += axes.z[i]
        }
        let n = Double(range.count)
        let mx = sx / n, my = sy / n, mz = sz / n
        let norm = (mx * mx + my * my + mz * mz).squareRoot()
        guard norm > 1e-6 else { return [Double](repeating: 0, count: range.count) }
        let gx = mx / norm, gy = my / norm, gz = mz / norm
        return range.map { axes.x[$0] * gx + axes.y[$0] * gy + axes.z[$0] * gz }
    }

    /// How much of the signal's power sits in the cadence band, and which
    /// frequency carries the most. Uses a direct Goertzel-style evaluation at a
    /// fixed set of frequencies rather than a full FFT: the band is narrow and
    /// the windows small, so this stays cheap and avoids needing a
    /// power-of-two length.
    private static func cadenceSpectrum(
        _ signal: [Double],
        sampleRateHz: Double
    ) -> (bandRatio: Double, dominantFrequency: Double) {
        let n = signal.count
        guard n > 8 else { return (0, 0) }

        // Hann window, matching the Python prototype this was validated with.
        let windowed = (0..<n).map { i -> Double in
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            return signal[i] * w
        }

        let resolution = sampleRateHz / Double(n)
        var bandPower = 0.0
        var totalPower = 0.0
        var peakPower = -1.0
        var peakFrequency = 0.0

        var freq = analysisBand.lowerBound
        while freq <= analysisBand.upperBound {
            let power = powerAt(frequency: freq, windowed, sampleRateHz: sampleRateHz)
            totalPower += power
            if cadenceBand.contains(freq) { bandPower += power }
            if power > peakPower {
                peakPower = power
                peakFrequency = freq
            }
            freq += resolution
        }

        guard totalPower > 1e-12 else { return (0, 0) }
        return (bandPower / totalPower, peakFrequency)
    }

    private static func powerAt(frequency: Double, _ signal: [Double], sampleRateHz: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRateHz
        var real = 0.0, imaginary = 0.0
        for (i, value) in signal.enumerated() {
            let angle = omega * Double(i)
            real += value * cos(angle)
            imaginary += value * sin(angle)
        }
        return real * real + imaginary * imaginary
    }

    /// Removes runs shorter than `minSamples`, in both directions, so short
    /// blips get absorbed by whichever state surrounds them.
    private static func enforceMinimumRunLength(_ mask: inout [Bool], minSamples: Int) {
        guard minSamples > 1, !mask.isEmpty else { return }
        for value in [true, false] {
            var runStart: Int?
            for i in 0...mask.count {
                let matches = i < mask.count && mask[i] == value
                if matches, runStart == nil {
                    runStart = i
                } else if !matches, let s = runStart {
                    if i - s < minSamples {
                        for j in s..<i { mask[j] = !value }
                    }
                    runStart = nil
                }
            }
        }
    }
}
