import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// Mechanical zones read off a 15 s rolling mean rather than each sample on its
/// own. The failure this prevents is subtle: classifying raw samples produces a
/// middle zone that holds ~4 % of the time whatever the athlete did, because
/// the figure tracks the band's width rather than the effort.
final class MechZoneRollingMeanTests: XCTestCase {

    private let fs = 50.0

    /// A stroke train: a burst, then nothing, at `strokesPerMinute`.
    private func strokes(seconds: Double, peak: Double, strokesPerMinute: Double) -> [Double] {
        let rate = strokesPerMinute / 60
        return (0..<Int(seconds * fs)).map { i in
            let phase = Double(i) / fs * rate
            let u = phase - phase.rounded(.down)
            return u < 0.45 ? peak * sin(.pi * u / 0.45) : 0
        }
    }

    private func zones(_ signal: [Double], low: Double, high: Double) -> (Double, Double, Double) {
        let s = ZoneTimeAccumulator.mechZoneSeconds(
            accelX: signal, sampleRateHz: fs, thresholdLow: low, thresholdHigh: high)
        let total = (s[.zone1] ?? 0) + (s[.zone2] ?? 0) + (s[.zone3] ?? 0)
        return (100 * (s[.zone1] ?? 0) / total,
                100 * (s[.zone2] ?? 0) / total,
                100 * (s[.zone3] ?? 0) / total)
    }

    // MARK: - The mean itself

    func testASteadySignalIsItsOwnMean() {
        // Every sample 2.0, so the mean is 2.0 everywhere and everything lands
        // in the zone containing 2.0 — no window arithmetic can hide here.
        let z = zones([Double](repeating: 2, count: Int(120 * fs)), low: 1, high: 3)
        XCTAssertEqual(z.1, 100, accuracy: 0.01, "2.0 sits between 1 and 3")
    }

    func testTheMeanIsTakenOverTheWholeWindowNotJustThePast() {
        // Half the recording at 4, then zero. A centred window puts the
        // crossing at the halfway point; a trailing one would put it 7.5 s late.
        var signal = [Double](repeating: 4, count: Int(60 * fs))
        signal += [Double](repeating: 0, count: Int(60 * fs))
        let s = ZoneTimeAccumulator.mechZoneSeconds(
            accelX: signal, sampleRateHz: fs, thresholdLow: 1, thresholdHigh: 2)
        XCTAssertEqual(s[.zone3] ?? 0, 60, accuracy: 2, "the loud half, give or take the window")
    }

    // MARK: - The reason for the change

    func testARollingMeanGivesTheMiddleZoneSomethingToHold() {
        // A stroke train whose average sits squarely in the middle band.
        let signal = strokes(seconds: 300, peak: 4, strokesPerMinute: 80)
        let mean = signal.reduce(0, +) / Double(signal.count)
        let z = zones(signal, low: mean * 0.7, high: mean * 1.3)

        XCTAssertGreaterThan(z.1, 95, "averaged first, the signal dwells in the band")
    }

    func testClassifyingRawSamplesWouldNotHave() {
        // The same signal, sample by sample: the band is crossed on the way up
        // and down and never occupied. This is the behaviour being replaced.
        let signal = strokes(seconds: 300, peak: 4, strokesPerMinute: 80)
        let mean = signal.reduce(0, +) / Double(signal.count)
        let low = mean * 0.7, high = mean * 1.3

        let dt = 1.0 / fs
        var inBand = 0.0
        for v in signal where v >= low && v < high { inBand += dt }
        let share = 100 * inBand / (Double(signal.count) * dt)

        XCTAssertLessThan(share, 15, "a crossing, not a stay")
    }

    // MARK: - Excluded stretches

    func testAnExcludedStretchNeitherCountsNorDilutes() {
        // Loud throughout, but the middle third is walking. Zone time must
        // cover two thirds, and the surviving thirds must still read loud —
        // if the excluded samples dragged the mean down they would not.
        let n = Int(90 * fs)
        let signal = [Double](repeating: 4, count: n)
        let mask = (0..<n).map { $0 < n / 3 || $0 >= 2 * n / 3 }

        let s = ZoneTimeAccumulator.mechZoneSeconds(
            accelX: signal, sampleRateHz: fs, thresholdLow: 1, thresholdHigh: 3, keepMask: mask)
        let total = (s[.zone1] ?? 0) + (s[.zone2] ?? 0) + (s[.zone3] ?? 0)

        XCTAssertEqual(total, 60, accuracy: 0.1, "two thirds of ninety seconds")
        XCTAssertEqual(s[.zone3] ?? 0, 60, accuracy: 0.1, "and all of it still loud")
    }

    // MARK: - Seconds above the anchor

    func testSecondsAboveAnchorCountsRealSeconds() {
        // Twenty seconds at 5, forty at 0.5, anchor 2: twenty seconds, and no
        // window can smear them.
        var signal = [Double](repeating: 5, count: Int(20 * fs))
        signal += [Double](repeating: 0.5, count: Int(40 * fs))

        let above = ZoneTimeAccumulator.secondsAboveAnchor(
            accelX: signal, sampleRateHz: fs, anchor: 2)
        XCTAssertEqual(above, 20, accuracy: 0.05)
    }

    func testSecondsAboveAnchorIsBlindToTheWindow() {
        // Bursts far shorter than the rolling window still count in full —
        // that is the whole point of keeping this figure alongside the zones.
        let signal = strokes(seconds: 60, peak: 6, strokesPerMinute: 60)
        let above = ZoneTimeAccumulator.secondsAboveAnchor(
            accelX: signal, sampleRateHz: fs, anchor: 3)
        XCTAssertGreaterThan(above, 10, "each stroke spends real time over 3")
        XCTAssertLessThan(above, 35, "but only part of its cycle")
    }

    func testNoAnchorMeansNoClaim() {
        let signal = [Double](repeating: 5, count: Int(30 * fs))
        XCTAssertEqual(
            ZoneTimeAccumulator.secondsAboveAnchor(accelX: signal, sampleRateHz: fs, anchor: 0),
            0, "an unset anchor cannot be exceeded")
    }
}

/// End-to-end through SessionAnalyzer, because the unit tests above all passed
/// while the analyser computed the figure and then left it out of the result
/// it returned. A default of zero on the initialiser made that compile in
/// silence, and the app showed an empty bar that read as "no hard work".
final class SessionAnalyzerCarriesEveryFigureTests: XCTestCase {

    /// A stroke train, not a constant: EffortSignal subtracts a 2 s moving
    /// average, so a steady value is gravity and posture by definition and
    /// comes out as no effort at all. The first draft of this test used a
    /// constant and measured 0.32 s — the analyser was right and the test was
    /// wrong, which is worth remembering before trusting a synthetic signal.
    func testSecondsAboveAnchorSurvivesTheAnalyser() throws {
        let fs = 50.0
        let accel = (0..<Int(240 * fs)).map { i -> Double in
            let phase = Double(i) / fs * (80.0 / 60)
            let u = phase - phase.rounded(.down)
            return u < 0.45 ? 6 * sin(.pi * u / 0.45) : 0
        }

        let raw = RawSessionData(
            startDate: .now,
            accelSampleRateHz: fs,
            accelX: accel,
            hrSamples: []
        )
        let result = SessionAnalyzer.analyze(
            session: raw,
            settings: AnalysisSettings(
                hrThresholdLow: 130, hrThresholdHigh: 160,
                mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                confirmedMech45sAnchor: 2.0
            )
        )

        XCTAssertGreaterThan(
            result.secondsAboveAnchor, 60,
            "the loud half is minutes long, not zero"
        )
    }

    func testNoAnchorStillReportsNothingRatherThanEverything() throws {
        let fs = 50.0
        let raw = RawSessionData(
            startDate: .now,
            accelSampleRateHz: fs,
            accelX: [Double](repeating: 6, count: Int(60 * fs)),
            hrSamples: []
        )
        let result = SessionAnalyzer.analyze(
            session: raw,
            settings: AnalysisSettings(
                hrThresholdLow: 130, hrThresholdHigh: 160,
                mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                confirmedMech45sAnchor: 0
            )
        )
        XCTAssertEqual(result.secondsAboveAnchor, 0, "nothing to exceed")
    }
}
