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

@Test func mechZoneSecondsClassifiesARollingMeanNotRawSamples() {
    // This test used to assert the opposite, and the reversal is the point.
    // Classifying each sample on its own gave a middle zone holding ~4 % of the
    // time in every session measured, because that figure follows the band's
    // width rather than the athlete's effort — the signal crosses the band
    // between strokes instead of staying in it. Averaging first is what lets a
    // zone be occupied.
    //
    // Four samples at 1 Hz sit well inside one 15 s window, so all four are
    // classified by the same mean: (1 + 5 + 9 + 0) / 4 = 3.75, which is
    // zone 2 for these thresholds.
    let accel: [Double] = [1.0, 5.0, 9.0, -2.0]   // -2.0 clamps to 0
    let seconds = ZoneTimeAccumulator.mechZoneSeconds(
        accelX: accel, sampleRateHz: 1, thresholdLow: 3, thresholdHigh: 7
    )
    #expect(seconds[.zone1] == 0)
    #expect(seconds[.zone2] == 4)
    #expect(seconds[.zone3] == 0)
    let total: Double = (seconds[.zone1] ?? 0) + (seconds[.zone2] ?? 0) + (seconds[.zone3] ?? 0)
    #expect(total == 4)
}
