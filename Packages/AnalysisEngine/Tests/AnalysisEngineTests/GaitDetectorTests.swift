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

    /// A hard paddling effort: a stroke near 1 Hz that throws the trunk around
    /// as much as walking does (vertical sd ~2.8 was measured on a real
    /// interval session), with a second harmonic landing inside the cadence
    /// band. This is the shape that used to be misread as walking.
    static func hardPaddling(seconds: Double, strokeHz: Double = 0.96) -> AccelerationAxes {
        let n = Int(seconds * sampleRate)
        var x = [Double](), y = [Double](), z = [Double]()
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let fundamental = 3.5 * sin(2 * .pi * strokeHz * t)
            let harmonic = 1.6 * sin(2 * .pi * 2 * strokeHz * t)
            y.append(gravity + fundamental + harmonic)
            x.append(3.0 * sin(2 * .pi * strokeHz * t))
            z.append(1.2 * sin(2 * .pi * strokeHz * t))
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

/// Regression test for the defect found on a real interval session
/// (2026-08-17): hard paddling bounces the trunk as hard as walking, and its
/// second harmonic falls in the cadence band, so a band-energy test alone
/// excluded 11 minutes of the athlete's best efforts.
@Test func hardPaddlingIsNotMistakenForWalking() {
    let result = GaitDetector.detect(
        axes: Signals.hardPaddling(seconds: 90),
        sampleRateHz: Signals.sampleRate
    )
    #expect(result.excludedSeconds == 0)
    #expect(result.keepMask.allSatisfy { $0 })
}

/// The efforts must survive even when real walking sits right beside them.
@Test func intervalEffortsSurviveBesideRealWalking() {
    let axes = Signals.concat([
        Signals.hardPaddling(seconds: 60),
        Signals.walking(seconds: 60),
        Signals.hardPaddling(seconds: 60),
    ])
    let result = GaitDetector.detect(axes: axes, sampleRateHz: Signals.sampleRate)

    // Only the middle minute should go.
    #expect(result.excludedSeconds > 45)
    #expect(result.excludedSeconds < 80)
    #expect(result.keepMask[Int(30 * Signals.sampleRate)])
    #expect(!result.keepMask[Int(90 * Signals.sampleRate)])
    #expect(result.keepMask[Int(150 * Signals.sampleRate)])
}

/// A cadence far outside the human walking range must not qualify, however
/// strong and rhythmic the bounce.
@Test func bounceOutsideWalkingCadenceIsIgnored() {
    let tooSlow = GaitDetector.detect(
        axes: Signals.walking(seconds: 60, stepHz: 0.8, verticalSD: 2.5),
        sampleRateHz: Signals.sampleRate
    )
    let tooFast = GaitDetector.detect(
        axes: Signals.walking(seconds: 60, stepHz: 3.4, verticalSD: 2.5),
        sampleRateHz: Signals.sampleRate
    )
    #expect(tooSlow.excludedSeconds == 0)
    #expect(tooFast.excludedSeconds == 0)
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

@Test func keptTimeRangesMapSamplesToSeconds() {
    // Keep 0..<10 s, drop 10..<20 s, keep 20..<30 s at 10 Hz.
    let mask = [Bool](repeating: true, count: 100)
        + [Bool](repeating: false, count: 100)
        + [Bool](repeating: true, count: 100)
    let ranges = GaitDetector.keptTimeRanges(keepMask: mask, sampleRateHz: 10)

    #expect(ranges.count == 2)
    #expect(abs(ranges[0].lowerBound - 0) < 0.001)
    #expect(abs(ranges[0].upperBound - 10) < 0.001)
    #expect(abs(ranges[1].lowerBound - 20) < 0.001)
    #expect(abs(ranges[1].upperBound - 30) < 0.001)
}

@Test func hrZoneTimeIgnoresExcludedStretches() {
    // A beat every second for 30 s: the first 10 s at 100 bpm, the middle 10 s
    // (which will be excluded) at 180, the last 10 s at 100.
    var samples: [HRSample] = []
    for second in 0..<30 {
        let bpm: Double = (10..<20).contains(second) ? 180 : 100
        samples.append(HRSample(timeOffset: TimeInterval(second), bpm: bpm))
    }
    let kept: [Range<TimeInterval>] = [0..<10, 20..<30]

    let withAll = ZoneTimeAccumulator.hrZoneSeconds(
        hrSamples: samples, sessionDuration: 30, thresholdLow: 120, thresholdHigh: 150
    )
    let withExclusion = ZoneTimeAccumulator.hrZoneSeconds(
        hrSamples: samples, sessionDuration: 30, thresholdLow: 120, thresholdHigh: 150,
        keptRanges: kept
    )

    // The excluded stretch is the only source of I3, so it must vanish, and
    // the total must fall to the kept span.
    #expect((withAll[.i3] ?? 0) > 9)
    #expect((withExclusion[.i3] ?? 0) == 0)
    #expect(abs(withExclusion.values.reduce(0, +) - 20) < 0.001)
}

/// Regression test for the defect found on two real recordings (2026-08-17):
/// the load axis carried gravity, so a sensor lying still — reading a steady
/// 8.4 with almost no variation — outscored actual paddling and took the
/// records.
@Test func aMotionlessSensorProducesNoLoad() {
    let rate = 52.0
    // Gravity resting on the load axis, plus the sensor's own noise.
    let atRest = (0..<Int(120 * rate)).map { i in
        8.4 + 0.02 * sin(Double(i) * 0.7)
    }
    let effort = EffortSignal.dynamic(atRest, sampleRateHz: rate)
    let curve = MechanicalCurveAnalyzer.analyze(accelX: effort, sampleRateHz: rate)

    for window in MechanicalWindow.allCases {
        guard let peak = curve.curve[window] ?? nil else { continue }
        #expect(peak < 0.1)
    }
}

/// And real movement must survive the correction, not be flattened with it.
@Test func strokeDynamicsSurviveGravityRemoval() {
    let rate = 52.0
    // A 1 Hz stroke of amplitude 3, riding on a tilt that drifts slowly.
    let signal = (0..<Int(120 * rate)).map { i -> Double in
        let t = Double(i) / rate
        let drift = 6.0 + 2.0 * sin(2 * .pi * 0.01 * t)
        return drift + 3.0 * sin(2 * .pi * 1.0 * t)
    }
    let effort = EffortSignal.dynamic(signal, sampleRateHz: rate)
    let curve = MechanicalCurveAnalyzer.analyze(accelX: effort, sampleRateHz: rate)

    // The positive half of a 3.0 sine averages about 0.95 over long windows.
    let peak45 = try! #require(curve.curve[.s45] ?? nil)
    #expect(peak45 > 0.7)
    #expect(peak45 < 1.3)
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
