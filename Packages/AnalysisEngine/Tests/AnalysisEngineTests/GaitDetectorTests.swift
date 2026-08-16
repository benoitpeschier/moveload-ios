import Testing
import Foundation
@testable import AnalysisEngine
import MoveLoadCore

/// Signals shaped like the two regimes measured on a real recording
/// (2026-08-16): walking bounces along gravity at step frequency with a
/// vertical standard deviation around 2.2 m/s²; paddling leaves the trunk
/// vertically quiet (around 0.46) and puts its motion into the horizontal
/// plane at a much lower rate.
private enum Signals {
    static let sampleRate = 52.0
    static let gravity = 9.81

    /// Gravity sits on Y, as it does with the sensor worn upright — the
    /// detector must not depend on that, which `rotated` checks.
    static func walking(seconds: Double, stepHz: Double = 1.75, verticalSD: Double = 2.2) -> AccelerationAxes {
        let n = Int(seconds * sampleRate)
        let amplitude = verticalSD * 2.0.squareRoot()  // sd of a sine is A/√2
        var x = [Double](), y = [Double](), z = [Double]()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            y.append(gravity + amplitude * sin(2 * .pi * stepHz * t))
            x.append(0.8 * sin(2 * .pi * stepHz * 1.5 * t))
            z.append(0.5 * sin(2 * .pi * stepHz * t))
        }
        return AccelerationAxes(x: x, y: y, z: z)
    }

    static func paddling(seconds: Double, strokeHz: Double = 0.5) -> AccelerationAxes {
        let n = Int(seconds * sampleRate)
        var x = [Double](), y = [Double](), z = [Double]()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            y.append(gravity + 0.5 * sin(2 * .pi * strokeHz * t))
            x.append(2.1 * sin(2 * .pi * strokeHz * t))
            z.append(0.9 * sin(2 * .pi * strokeHz * t))
        }
        return AccelerationAxes(x: x, y: y, z: z)
    }

    static func concat(_ parts: [AccelerationAxes]) -> AccelerationAxes {
        AccelerationAxes(
            x: parts.flatMap(\.x),
            y: parts.flatMap(\.y),
            z: parts.flatMap(\.z)
        )
    }

    /// Same motion with the axes cycled, standing in for the sensor being
    /// strapped on in a different orientation.
    static func rotated(_ axes: AccelerationAxes) -> AccelerationAxes {
        AccelerationAxes(x: axes.y, y: axes.z, z: axes.x)
    }
}

@Test func walkingIsDetected() {
    let result = GaitDetector.detect(axes: Signals.walking(seconds: 60), sampleRateHz: Signals.sampleRate)
    let keptFraction = Double(result.keepMask.filter { $0 }.count) / Double(result.keepMask.count)
    #expect(keptFraction < 0.1)
    #expect(result.excludedSeconds > 50)
}

@Test func paddlingIsKeptWhole() {
    let result = GaitDetector.detect(axes: Signals.paddling(seconds: 60), sampleRateHz: Signals.sampleRate)
    #expect(result.keepMask.allSatisfy { $0 })
    #expect(result.excludedSeconds == 0)
}

@Test func detectionSurvivesSensorReorientation() {
    let upright = GaitDetector.detect(axes: Signals.walking(seconds: 60), sampleRateHz: Signals.sampleRate)
    let rotated = GaitDetector.detect(
        axes: Signals.rotated(Signals.walking(seconds: 60)),
        sampleRateHz: Signals.sampleRate
    )
    // Projecting onto measured gravity, not a fixed axis, is the whole point.
    #expect(abs(upright.excludedSeconds - rotated.excludedSeconds) < 2.0)
}

@Test func mixedSessionExcludesOnlyTheWalkingPart() {
    let axes = Signals.concat([
        Signals.walking(seconds: 40),
        Signals.paddling(seconds: 80),
        Signals.walking(seconds: 40),
    ])
    let result = GaitDetector.detect(axes: axes, sampleRateHz: Signals.sampleRate)

    // 80 s of walking out of 160 s, give or take the window-edge blending.
    #expect(result.excludedSeconds > 65)
    #expect(result.excludedSeconds < 95)

    // The middle should survive, the ends should not.
    let mid = result.keepMask.count / 2
    #expect(result.keepMask[mid])
    #expect(!result.keepMask[Int(10 * Signals.sampleRate)])
    #expect(!result.keepMask[result.keepMask.count - Int(10 * Signals.sampleRate)])
}

@Test func sessionTooShortToJudgeIsKept() {
    let result = GaitDetector.detect(axes: Signals.walking(seconds: 2), sampleRateHz: Signals.sampleRate)
    #expect(result.keepMask.allSatisfy { $0 })
}

@Test func curveWindowsNeverSpanAnExcludedGap() {
    // Two 10 s bursts of 5.0 either side of an excluded stretch. A window
    // longer than one burst must not find 5.0 by bridging the gap.
    let rate = 10.0
    let burst = [Double](repeating: 5.0, count: Int(10 * rate))
    let excluded = [Double](repeating: 100.0, count: Int(60 * rate))
    let signal = burst + excluded + burst
    let mask = [Bool](repeating: true, count: burst.count)
        + [Bool](repeating: false, count: excluded.count)
        + [Bool](repeating: true, count: burst.count)

    let result = MechanicalCurveAnalyzer.analyze(accelX: signal, sampleRateHz: rate, keepMask: mask)

    #expect((result.curve[.s9] ?? nil).map { abs($0 - 5.0) < 0.001 } == true)
    // 15 s exceeds either kept run, so there is no honest value for it.
    #expect((result.curve[.s15] ?? nil) == nil)
    // And the excluded 100.0 must not leak into any window.
    for window in MechanicalWindow.allCases {
        if let peak = result.curve[window] ?? nil {
            #expect(peak <= 5.001)
        }
    }
}
