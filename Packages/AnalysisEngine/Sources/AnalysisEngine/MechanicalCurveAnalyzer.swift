import Foundation
import MoveLoadCore

public enum MechanicalCurveAnalyzer {
    public struct Result: Sendable {
        public let curve: [MechanicalWindow: Double?]
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
        for window in MechanicalWindow.allCases { best[window] = nil }

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
                    best[window] = current.map { Swift.max($0, value) } ?? value
                }
                runStart = nil
            }
        }

        return Result(curve: best)
    }

    public static func analyze(accelX: [Double], sampleRateHz: Double) -> Result {
        let positive = accelX.map { max(0, $0) }
        let count = positive.count
        let windows = MechanicalWindow.allCases
        let windowSamples = windows.map { Int(($0.seconds * sampleRateHz).rounded()) }

        var sums = [Double](repeating: 0, count: windows.count)
        var peaks = [Double](repeating: -.infinity, count: windows.count)

        for i in 0..<count {
            for w in windows.indices {
                let n = windowSamples[w]
                guard n > 0 else { continue }
                sums[w] += positive[i]
                if i >= n { sums[w] -= positive[i - n] }
                if i >= n - 1 {
                    let mean = sums[w] / Double(n)
                    peaks[w] = max(peaks[w], mean)
                }
            }
        }

        var curve: [MechanicalWindow: Double?] = [:]
        for w in windows.indices {
            let n = windowSamples[w]
            curve[windows[w]] = (n > 0 && n <= count && peaks[w].isFinite) ? peaks[w] : nil
        }

        return Result(curve: curve)
    }
}
