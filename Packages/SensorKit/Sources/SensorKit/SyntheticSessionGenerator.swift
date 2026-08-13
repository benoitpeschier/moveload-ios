import Foundation
import MoveLoadCore

enum SyntheticSessionGenerator {
    static let accelSampleRateHz: Double = 52

    static func generate(startDate: Date, duration: TimeInterval, intensityMultiplier: Double = 1.0) -> RawSessionData {
        let sampleCount = max(1, Int(duration * accelSampleRateHz))
        var accel: [Double] = []
        accel.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let t = Double(i) / accelSampleRateHz
            let f = t / duration
            let effortEnvelope = max(0, sin(f * .pi * 8))
            let burst = effortEnvelope * Double.random(in: 2...6) * intensityMultiplier
            let noise = Double.random(in: -0.3...0.3)
            accel.append(max(0, burst + noise))
        }

        var hr: [HRSample] = []
        var t = 0.0
        while t < duration {
            let f = t / duration
            let bpm = hrShape(fractionOfSession: f) + Double.random(in: -3...3)
            hr.append(HRSample(timeOffset: t, bpm: max(55, bpm)))
            t += 2.0
        }

        return RawSessionData(startDate: startDate, accelSampleRateHz: accelSampleRateHz, accelX: accel, hrSamples: hr)
    }

    /// Repos -> montée -> intervalles -> récupération, exprimé sur la fraction [0,1] de la séance.
    private static func hrShape(fractionOfSession f: Double) -> Double {
        switch f {
        case ..<0.1:
            return 70
        case ..<0.3:
            let local = (f - 0.1) / 0.2
            return 70 + local * 90
        case ..<0.8:
            let local = (f - 0.3) / 0.5
            let oscillation = sin(local * .pi * 6)
            return 150 + oscillation * 20
        default:
            let local = (f - 0.8) / 0.2
            return 150 - local * 60
        }
    }
}
