import Foundation
import MoveLoadCore

public enum MechanicalCurveAnalyzer {
    public struct Result: Sendable {
        public let curve: [MechanicalWindow: Double?]
        /// Where each peak was achieved, as the window's start offset in
        /// seconds from the beginning of the session. Lets the effort be
        /// located in the recording — to show what the heart was doing during
        /// it, for one — rather than only reported as a number.
        public let peakStartSeconds: [MechanicalWindow: Double?]

        public init(
            curve: [MechanicalWindow: Double?],
            peakStartSeconds: [MechanicalWindow: Double?] = [:]
        ) {
            self.curve = curve
            self.peakStartSeconds = peakStartSeconds
        }
    }

    /// Peaks over the kept samples only. Each contiguous kept run is scored
    /// on its own and the best result wins, so no rolling window ever spans
    /// an excluded stretch — concatenating the runs instead would average
    /// across a time discontinuity and report an effort that never happened.
    public static func analyze(accelX: [Double], sampleRateHz: Double, keepMask: [Bool]) -> Result {
        guard keepMask.count == accelX.count else {
            return analyze(accelX: accelX, sampleRateHz: sampleRateHz)
        }

        var best: [MechanicalWindow: Double?] = [:]
        var bestStart: [MechanicalWindow: Double?] = [:]
        for window in MechanicalWindow.allCases {
            best[window] = nil
            bestStart[window] = nil
        }

        var runStart: Int?
        for i in 0...accelX.count {
            let keep = i < accelX.count && keepMask[i]
            if keep, runStart == nil {
                runStart = i
            } else if !keep, let start = runStart {
                let run = Array(accelX[start..<i])
                let result = analyze(accelX: run, sampleRateHz: sampleRateHz)
                for window in MechanicalWindow.allCases {
                    guard let value = result.curve[window] ?? nil else { continue }
                    let current = best[window] ?? nil
                    if current == nil || value > current! {
                        best[window] = value
                        // Offsets come back relative to the run, so shift them
                        // to the whole recording's timeline.
                        bestStart[window] = (result.peakStartSeconds[window] ?? nil)
                            .map { $0 + Double(start) / sampleRateHz }
                    }
                }
                runStart = nil
            }
        }

        return Result(curve: best, peakStartSeconds: bestStart)
    }

    public static func analyze(accelX: [Double], sampleRateHz: Double) -> Result {
        let positive = accelX.map { max(0, $0) }
        let count = positive.count
        let windows = MechanicalWindow.allCases
        let windowSamples = windows.map { Int(($0.seconds * sampleRateHz).rounded()) }

        var sums = [Double](repeating: 0, count: windows.count)
        var peaks = [Double](repeating: -.infinity, count: windows.count)
        var peakStartIndex = [Int](repeating: 0, count: windows.count)

        for i in 0..<count {
            for w in windows.indices {
                let n = windowSamples[w]
                guard n > 0 else { continue }
                sums[w] += positive[i]
                if i >= n { sums[w] -= positive[i - n] }
                if i >= n - 1 {
                    let mean = sums[w] / Double(n)
                    if mean > peaks[w] {
                        peaks[w] = mean
                        peakStartIndex[w] = i - n + 1
                    }
                }
            }
        }

        var curve: [MechanicalWindow: Double?] = [:]
        var starts: [MechanicalWindow: Double?] = [:]
        for w in windows.indices {
            let n = windowSamples[w]
            let usable = n > 0 && n <= count && peaks[w].isFinite
            curve[windows[w]] = usable ? peaks[w] : nil
            starts[windows[w]] = usable ? Double(peakStartIndex[w]) / sampleRateHz : nil
        }

        return Result(curve: curve, peakStartSeconds: starts)
    }
}
