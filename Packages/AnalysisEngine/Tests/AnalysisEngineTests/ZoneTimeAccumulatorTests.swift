import Testing
@testable import AnalysisEngine
import MoveLoadCore

@Test func hrZoneSecondsSplitsAcrossThresholds() {
    let samples = [
        HRSample(timeOffset: 0, bpm: 100),   // zone1: [0,10)
        HRSample(timeOffset: 10, bpm: 140),  // zone2: [10,20)
        HRSample(timeOffset: 20, bpm: 170),  // zone3: [20,30)
    ]
    let seconds = ZoneTimeAccumulator.hrZoneSeconds(
        hrSamples: samples, sessionDuration: 30, thresholdLow: 120, thresholdHigh: 160
    )
    #expect(seconds[.i1] == 10)
    #expect(seconds[.i2] == 10)
    #expect(seconds[.i3] == 10)
}

@Test func mechZoneSecondsClassifiesRawSamplesNotARollingMean() {
    let accel: [Double] = [1.0, 5.0, 9.0, -2.0]
    let seconds = ZoneTimeAccumulator.mechZoneSeconds(
        accelX: accel, sampleRateHz: 1, thresholdLow: 3, thresholdHigh: 7
    )
    #expect(seconds[.zone1] == 2) // 1.0, and -2.0 clamped to 0
    #expect(seconds[.zone2] == 1) // 5.0
    #expect(seconds[.zone3] == 1) // 9.0
    let total: Double = (seconds[.zone1] ?? 0) + (seconds[.zone2] ?? 0) + (seconds[.zone3] ?? 0)
    #expect(total == 4)
}
