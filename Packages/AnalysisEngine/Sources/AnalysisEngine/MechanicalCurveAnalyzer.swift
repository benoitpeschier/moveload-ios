import Foundation
import MoveLoadCore

public enum MechanicalCurveAnalyzer {
    public struct Result: Sendable {
        public let curve: [MechanicalWindow: Double?]
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
