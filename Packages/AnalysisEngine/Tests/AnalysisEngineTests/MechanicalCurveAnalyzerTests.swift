import Testing
@testable import AnalysisEngine
import MoveLoadCore

@Test func constantSignalPeakEqualsValueForFullWindows() {
    let rate = 10.0
    let samples = Array(repeating: 2.0, count: Int(200 * rate)) // 200s, covers all windows except 180s edge
    let result = MechanicalCurveAnalyzer.analyze(accelX: samples, sampleRateHz: rate)

    for window in MechanicalWindow.allCases {
        #expect(result.curve[window]! != nil)
        #expect(abs(result.curve[window]!! - 2.0) < 0.0001)
    }
}

@Test func sessionShorterThanWindowYieldsNilPeak() {
    let rate = 10.0
    let samples = Array(repeating: 1.0, count: Int(20 * rate)) // 20s: only windows <=20s fit (3/6/9/15)
    let result = MechanicalCurveAnalyzer.analyze(accelX: samples, sampleRateHz: rate)

    #expect(result.curve[.s3]! != nil)
    #expect(result.curve[.s15]! != nil)
    #expect(result.curve[.s30]! == nil)
    #expect(result.curve[.s180]! == nil)
}

@Test func negativeAccelerationIsClampedToZero() {
    let rate = 10.0
    let samples = Array(repeating: -5.0, count: Int(10 * rate))
    let result = MechanicalCurveAnalyzer.analyze(accelX: samples, sampleRateHz: rate)
    #expect(result.curve[.s3]!! == 0)
}

