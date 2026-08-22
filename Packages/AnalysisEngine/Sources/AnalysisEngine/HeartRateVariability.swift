import Foundation

/// Heart rate variability from a series of R-R intervals, for the orthostatic
/// test: one recording lying down, one standing, compared against the
/// athlete's own recent tests.
///
/// Everything here works on intervals in **milliseconds** and returns spectral
/// power in **ms²**, which is what the HRV literature and the coach's existing
/// workbook use. Feeding it seconds would produce numbers a million times too
/// small with nothing to say so.
public enum HeartRateVariability {

    // MARK: - Bands

    /// Task Force (1996) bands. VLF is included because the workbook's
    /// automatic assessment leans on it, but see `isFrequencyDomainReliable`:
    /// resolving 0.003 Hz needs a recording longer than the 5 minutes this
    /// test actually lasts, so VLF is the number to trust least.
    public static let vlfBand: ClosedRange<Double> = 0.003...0.04
    public static let lfBand: ClosedRange<Double> = 0.04...0.15
    public static let hfBand: ClosedRange<Double> = 0.15...0.40

    /// The tachogram is resampled onto an even time base before the spectrum.
    /// 4 Hz is the conventional choice: comfortably above twice the 0.4 Hz top
    /// of the HF band, and low enough not to invent detail between beats.
    public static let resampleHz: Double = 4.0

    /// An interval this far from its neighbours is a missed or extra beat, not
    /// a heartbeat. 20 % is the usual threshold.
    public static let artifactTolerance: Double = 0.20

    /// Above this share of corrected beats the spectrum is not worth reading —
    /// a single misplaced beat puts a spike across LF and HF alike.
    public static let maxCorrectedFraction: Double = 0.05

    /// Below this, the frequency-domain figures are reported but flagged.
    public static let minimumSecondsForSpectrum: Double = 240

    // MARK: - Result

    public struct Result: Sendable, Equatable {
        // Time domain
        public let meanRRms: Double
        public let meanHRbpm: Double
        /// Root mean square of successive differences — short-term
        /// parasympathetic activity, and the most artifact-tolerant of the
        /// frequency-free measures.
        public let rmssdMs: Double

        // Frequency domain, absolute power in ms²
        public let vlf: Double
        public let lf: Double
        public let hf: Double
        /// VLF + LF + HF. The workbook calls this "énergie totale".
        public let totalPower: Double

        public let lfOverHf: Double
        /// LF and HF as a share of LF+HF, in percent. Independent of total
        /// power, so they stay comparable between two days whose overall
        /// energy differs — which absolute LF and HF do not.
        public let lfNormalised: Double
        public let hfNormalised: Double

        // Quality — reported rather than silently applied, because a reading
        // taken from a noisy recording should be visibly a bad reading.
        public let beatCount: Int
        public let durationSeconds: Double
        public let correctedFraction: Double
        public let isFrequencyDomainReliable: Bool
    }

    // MARK: - Entry point

    /// - Parameter rrIntervalsMs: consecutive R-R intervals in milliseconds.
    /// - Returns: nil when there are too few beats to say anything at all.
    public static func analyse(rrIntervalsMs: [Double]) -> Result? {
        let (corrected, correctedFraction) = correctingArtifacts(rrIntervalsMs)
        guard corrected.count >= 4 else { return nil }

        let meanRR = corrected.reduce(0, +) / Double(corrected.count)
        guard meanRR > 0 else { return nil }

        var sumSquaredDiffs = 0.0
        for i in 1..<corrected.count {
            let d = corrected[i] - corrected[i - 1]
            sumSquaredDiffs += d * d
        }
        let rmssd = (sumSquaredDiffs / Double(corrected.count - 1)).squareRoot()

        let durationSeconds = corrected.reduce(0, +) / 1000
        let spectrum = bandPowers(of: corrected)
        let total = spectrum.vlf + spectrum.lf + spectrum.hf
        let lfPlusHf = spectrum.lf + spectrum.hf

        return Result(
            meanRRms: meanRR,
            meanHRbpm: 60_000 / meanRR,
            rmssdMs: rmssd,
            vlf: spectrum.vlf,
            lf: spectrum.lf,
            hf: spectrum.hf,
            totalPower: total,
            lfOverHf: spectrum.hf > 0 ? spectrum.lf / spectrum.hf : 0,
            lfNormalised: lfPlusHf > 0 ? 100 * spectrum.lf / lfPlusHf : 0,
            hfNormalised: lfPlusHf > 0 ? 100 * spectrum.hf / lfPlusHf : 0,
            beatCount: corrected.count,
            durationSeconds: durationSeconds,
            correctedFraction: correctedFraction,
            isFrequencyDomainReliable: correctedFraction <= maxCorrectedFraction
                && durationSeconds >= minimumSecondsForSpectrum
        )
    }

    // MARK: - Artifact correction

    /// Replaces intervals that are too far from their local surroundings with
    /// the local median, and reports how many were replaced.
    ///
    /// Correcting rather than deleting matters: dropping a beat shortens the
    /// tachogram and shifts every later timestamp, which shows up in the
    /// spectrum as a trend that was never in the heart.
    static func correctingArtifacts(_ intervals: [Double]) -> (corrected: [Double], fraction: Double) {
        guard intervals.count >= 5 else { return (intervals, 0) }

        var out = intervals
        var corrections = 0
        let half = 2   // five-beat window, the beat itself plus two either side

        for i in intervals.indices {
            let lower = max(0, i - half)
            let upper = min(intervals.count - 1, i + half)
            var neighbours = [Double]()
            for j in lower...upper where j != i { neighbours.append(intervals[j]) }
            neighbours.sort()
            let localMedian = median(of: neighbours)
            guard localMedian > 0 else { continue }

            if abs(intervals[i] - localMedian) / localMedian > artifactTolerance {
                out[i] = localMedian
                corrections += 1
            }
        }

        return (out, Double(corrections) / Double(intervals.count))
    }

    private static func median(of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Spectrum

    struct BandPowers { let vlf: Double; let lf: Double; let hf: Double }

    /// Power in each band, in ms².
    ///
    /// The whole recording is taken as a **single** windowed periodogram
    /// rather than split into Welch segments. Splitting would steady the
    /// estimate, but each segment would then be far too short to resolve the
    /// bottom of the VLF band — a 0.003 Hz component needs over five minutes
    /// in one piece. Given the test itself only lasts about five minutes, one
    /// segment is the only way VLF means anything at all.
    static func bandPowers(of intervalsMs: [Double]) -> BandPowers {
        let series = resampled(intervalsMs)
        guard series.count >= 8 else { return BandPowers(vlf: 0, lf: 0, hf: 0) }

        let detrended = linearlyDetrended(series)

        // Hann window, and the coherent gain it costs is divided back out below.
        let n = detrended.count
        var windowed = [Double](repeating: 0, count: n)
        var windowPowerSum = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
            windowed[i] = detrended[i] * w
            windowPowerSum += w * w
        }

        // Zero-pad to a power of two for the radix-2 transform. Padding
        // interpolates the spectrum; it does not add resolution, and the band
        // sums below are unaffected because the scaling uses the original
        // window's power.
        var padded = windowed
        var size = 1
        while size < n { size <<= 1 }
        padded.append(contentsOf: [Double](repeating: 0, count: size - n))

        var real = padded
        var imag = [Double](repeating: 0, count: size)
        fft(&real, &imag)

        let deltaF = resampleHz / Double(size)
        var vlf = 0.0, lf = 0.0, hf = 0.0

        // One-sided spectrum: bins below Nyquist carry their mirror's power too.
        for k in 1..<(size / 2) {
            let frequency = Double(k) * deltaF
            if frequency > hfBand.upperBound { break }

            let magnitudeSquared = real[k] * real[k] + imag[k] * imag[k]
            let density = 2 * magnitudeSquared / (resampleHz * windowPowerSum)
            let power = density * deltaF

            if vlfBand.contains(frequency) { vlf += power }
            else if lfBand.contains(frequency) { lf += power }
            else if hfBand.contains(frequency) { hf += power }
        }

        return BandPowers(vlf: vlf, lf: lf, hf: hf)
    }

    /// The tachogram onto an even time base.
    ///
    /// Beats do not arrive on a clock, so each interval is placed at the time
    /// its beat occurred and the values between beats are interpolated with a
    /// natural cubic spline.
    ///
    /// The spline is not a refinement — straight lines lose real power here.
    /// A heart beating around 900 ms gives only about 4.4 beats per cycle of a
    /// 0.25 Hz respiratory rhythm, and chords drawn between so few points cut
    /// the peaks off: measured against a synthetic sine of known amplitude,
    /// linear interpolation returned 323 ms² where the true variance was 450.
    /// Worse, the loss grows with frequency, so it flattened HF far more than
    /// LF and dragged LF/HF and the normalised units with it. The spline
    /// returns 442. What remains at the very top of the band is the beats
    /// themselves being too sparse to carry it, which no interpolation fixes.
    static func resampled(_ intervalsMs: [Double]) -> [Double] {
        guard intervalsMs.count >= 4 else { return [] }

        var times = [Double]()
        times.reserveCapacity(intervalsMs.count)
        var clock = 0.0
        for interval in intervalsMs {
            clock += interval / 1000
            times.append(clock)
        }

        let n = intervalsMs.count
        let span = times[n - 1] - times[0]
        guard span > 0 else { return [] }
        let count = Int(span * resampleHz)
        guard count >= 8 else { return [] }

        // Natural cubic spline: second derivative zero at both ends, solved
        // with the Thomas algorithm for the tridiagonal system.
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { h[i] = times[i + 1] - times[i] }
        guard h.allSatisfy({ $0 > 0 }) else { return [] }

        var alpha = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            alpha[i] = 3 * ((intervalsMs[i + 1] - intervalsMs[i]) / h[i]
                          - (intervalsMs[i] - intervalsMs[i - 1]) / h[i - 1])
        }

        var l = [Double](repeating: 0, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        l[0] = 1
        for i in 1..<(n - 1) {
            l[i] = 2 * (times[i + 1] - times[i - 1]) - h[i - 1] * mu[i - 1]
            guard l[i] != 0 else { return [] }
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i]
        }

        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        for j in stride(from: n - 2, through: 0, by: -1) {
            c[j] = z[j] - mu[j] * c[j + 1]
            b[j] = (intervalsMs[j + 1] - intervalsMs[j]) / h[j] - h[j] * (c[j + 1] + 2 * c[j]) / 3
            d[j] = (c[j + 1] - c[j]) / (3 * h[j])
        }

        var out = [Double](repeating: 0, count: count)
        var cursor = 0
        for i in 0..<count {
            let t = times[0] + Double(i) / resampleHz
            while cursor < n - 2 && times[cursor + 1] < t { cursor += 1 }
            let dt = t - times[cursor]
            out[i] = intervalsMs[cursor] + b[cursor] * dt + c[cursor] * dt * dt + d[cursor] * dt * dt * dt
        }
        return out
    }

    /// Removes the mean and any straight-line drift.
    ///
    /// A tachogram that slides steadily — the settling after standing up, for
    /// instance — puts a large component at the very bottom of the spectrum
    /// that would otherwise be counted as VLF.
    static func linearlyDetrended(_ values: [Double]) -> [Double] {
        let n = Double(values.count)
        guard n > 1 else { return values }

        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for (i, v) in values.enumerated() {
            let x = Double(i)
            sumX += x; sumY += v; sumXY += x * v; sumXX += x * x
        }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return values }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n
        return values.enumerated().map { $0.element - (slope * Double($0.offset) + intercept) }
    }

    /// In-place iterative radix-2 Cooley-Tukey transform.
    ///
    /// Written out rather than taken from Accelerate so this package stays
    /// pure Foundation and its tests run with `swift test`, no simulator — the
    /// same reason the SBEM decoder is hand-written. At these sizes (a few
    /// thousand points) the difference in speed does not matter.
    static func fft(_ real: inout [Double], _ imag: inout [Double]) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wReal = cos(angle), wImag = sin(angle)
            var start = 0
            while start < n {
                var curReal = 1.0, curImag = 0.0
                for k in 0..<(length / 2) {
                    let a = start + k
                    let b = a + length / 2
                    let tReal = real[b] * curReal - imag[b] * curImag
                    let tImag = real[b] * curImag + imag[b] * curReal
                    real[b] = real[a] - tReal
                    imag[b] = imag[a] - tImag
                    real[a] += tReal
                    imag[a] += tImag
                    let nextReal = curReal * wReal - curImag * wImag
                    curImag = curReal * wImag + curImag * wReal
                    curReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }
}
