import XCTest
@testable import AnalysisEngine

final class HeartRateVariabilityTests: XCTestCase {

    /// A tachogram of `beats` intervals around `meanMs`, modulated by a sine
    /// at `hz` — a heart whose rate rises and falls at a known frequency, so
    /// the spectrum has a right answer to be checked against.
    private func tachogram(meanMs: Double, amplitudeMs: Double, hz: Double, seconds: Double) -> [Double] {
        var intervals = [Double]()
        var clock = 0.0
        while clock < seconds {
            let value = meanMs + amplitudeMs * sin(2 * .pi * hz * clock)
            intervals.append(value)
            clock += value / 1000
        }
        return intervals
    }

    // MARK: - Time domain

    func testMeanAndHeartRate() throws {
        // 1000 ms between beats is exactly 60 bpm — the one case needing no
        // arithmetic to check.
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: Array(repeating: 1000, count: 300)))
        XCTAssertEqual(result.meanRRms, 1000, accuracy: 0.001)
        XCTAssertEqual(result.meanHRbpm, 60, accuracy: 0.001)
    }

    func testRmssdOfAPerfectlySteadyHeartIsZero() throws {
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: Array(repeating: 850, count: 100)))
        XCTAssertEqual(result.rmssdMs, 0, accuracy: 1e-9)
    }

    func testRmssdAgainstAHandComputedCase() throws {
        // Differences: +20, -10, +30. Mean square = (400+100+900)/3 = 466.66…
        let intervals = [800.0, 820, 810, 840]
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))
        XCTAssertEqual(result.rmssdMs, (1400.0 / 3).squareRoot(), accuracy: 1e-9)
    }

    // MARK: - Artifact correction

    func testAMissedBeatIsCorrectedNotKept() {
        var intervals = [Double](repeating: 800, count: 40)
        intervals[20] = 1600   // two beats recorded as one
        let (corrected, fraction) = HeartRateVariability.correctingArtifacts(intervals)

        XCTAssertEqual(corrected[20], 800, accuracy: 1e-9)
        XCTAssertEqual(corrected.count, intervals.count, "correcting must not shorten the tachogram")
        XCTAssertEqual(fraction, 1.0 / 40, accuracy: 1e-9)
    }

    func testCleanRecordingReportsNoCorrections() throws {
        let intervals = tachogram(meanMs: 900, amplitudeMs: 25, hz: 0.25, seconds: 300)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))
        XCTAssertEqual(result.correctedFraction, 0, accuracy: 1e-9)
        XCTAssertTrue(result.isFrequencyDomainReliable)
    }

    // MARK: - Frequency domain

    func testPowerLandsInTheHighFrequencyBand() throws {
        // 0.25 Hz sits in HF (0.15–0.40) — respiratory rhythm, roughly 15
        // breaths a minute.
        let intervals = tachogram(meanMs: 900, amplitudeMs: 30, hz: 0.25, seconds: 300)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))

        XCTAssertGreaterThan(result.hf, result.lf * 10)
        XCTAssertGreaterThan(result.hf, result.vlf * 10)
        XCTAssertGreaterThan(result.hfNormalised, 90)
        XCTAssertLessThan(result.lfOverHf, 0.1)
    }

    func testPowerLandsInTheLowFrequencyBand() throws {
        // 0.10 Hz is the baroreflex rhythm, the middle of LF.
        let intervals = tachogram(meanMs: 900, amplitudeMs: 30, hz: 0.10, seconds: 300)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))

        XCTAssertGreaterThan(result.lf, result.hf * 10)
        XCTAssertGreaterThan(result.lfNormalised, 90)
        XCTAssertGreaterThan(result.lfOverHf, 10)
    }

    /// Parseval: the power in the spectrum must equal the variance of the
    /// signal it came from. For a sine of amplitude A that is A²/2.
    func testAbsolutePowerMatchesTheSignalVariance() throws {
        let amplitude = 30.0
        let intervals = tachogram(meanMs: 900, amplitudeMs: amplitude, hz: 0.25, seconds: 300)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))

        let expected = amplitude * amplitude / 2       // ms²
        XCTAssertEqual(result.totalPower, expected, accuracy: expected * 0.15)
    }

    func testNormalisedUnitsSumToOneHundred() throws {
        let intervals = tachogram(meanMs: 880, amplitudeMs: 20, hz: 0.12, seconds: 300)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))
        XCTAssertEqual(result.lfNormalised + result.hfNormalised, 100, accuracy: 1e-6)
    }

    /// The reason normalised units are worth having: doubling every
    /// oscillation quadruples absolute LF and HF but leaves the balance
    /// between the two branches untouched.
    func testNormalisedUnitsSurviveAChangeInTotalPower() throws {
        let quiet = try XCTUnwrap(HeartRateVariability.analyse(
            rrIntervalsMs: tachogram(meanMs: 900, amplitudeMs: 15, hz: 0.25, seconds: 300)))
        let loud = try XCTUnwrap(HeartRateVariability.analyse(
            rrIntervalsMs: tachogram(meanMs: 900, amplitudeMs: 30, hz: 0.25, seconds: 300)))

        XCTAssertGreaterThan(loud.hf, quiet.hf * 3)
        XCTAssertEqual(loud.hfNormalised, quiet.hfNormalised, accuracy: 2)
    }

    // MARK: - Quality reporting

    func testAShortRecordingIsFlaggedRatherThanRefused() throws {
        let intervals = tachogram(meanMs: 900, amplitudeMs: 25, hz: 0.25, seconds: 90)
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: intervals))

        XCTAssertGreaterThan(result.hf, 0, "the figures are still produced")
        XCTAssertFalse(result.isFrequencyDomainReliable, "but they are marked untrustworthy")
    }

    func testTooFewBeatsGivesNothing() {
        XCTAssertNil(HeartRateVariability.analyse(rrIntervalsMs: [800, 810]))
        XCTAssertNil(HeartRateVariability.analyse(rrIntervalsMs: []))
    }

    // MARK: - Detrending

    func testDetrendingRemovesASteadyDrift() {
        // Standing up: the rate settles over the recording. Left in, that ramp
        // would be counted as very low frequency power.
        let ramp = (0..<200).map { 900 - Double($0) }
        let flat = HeartRateVariability.linearlyDetrended(ramp)
        for value in flat {
            XCTAssertEqual(value, 0, accuracy: 1e-9)
        }
    }
}

/// The protocol drops 30 s from each end of every position, so a five-minute
/// recording is read on its middle four. The first half-minute is the
/// transition into the position rather than the position itself.
final class HeartRateVariabilityTrimTests: XCTestCase {

    private func steady(seconds: Double, ms: Double = 1000) -> [Double] {
        Array(repeating: ms, count: Int(seconds * 1000 / ms))
    }

    func testFiveMinutesBecomesFour() {
        let kept = HeartRateVariability.trimmingEnds(steady(seconds: 300), by: 30)
        XCTAssertEqual(kept.reduce(0, +) / 1000, 240, accuracy: 1.5)
    }

    func testTrimTakesTimeNotBeatCount() {
        // Fast beats: 600 ms each, so 30 s is fifty of them, not thirty.
        let kept = HeartRateVariability.trimmingEnds(steady(seconds: 300, ms: 600), by: 30)
        XCTAssertEqual(kept.reduce(0, +) / 1000, 240, accuracy: 1.5)
    }

    /// A series too short to give up a minute is not a test recording. Trimming
    /// it to nothing would come back later as an unexplained nil, so it is left
    /// whole and caught by the duration check instead.
    func testAShortSeriesIsLeftAlone() {
        let short = steady(seconds: 40)
        XCTAssertEqual(HeartRateVariability.trimmingEnds(short, by: 30).count, short.count)
    }

    func testTrimmingIsAppliedByDefault() throws {
        let full = steady(seconds: 300)
        let trimmed = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: full))
        let whole = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: full, trimmingSeconds: 0))

        XCTAssertEqual(trimmed.durationSeconds, 240, accuracy: 1.5)
        XCTAssertEqual(whole.durationSeconds, 300, accuracy: 1.5)
    }

    /// A well-run test must not be flagged. Trimmed from exactly five minutes
    /// it lands a hair under four, and a flag that fires on every good
    /// recording is a flag nobody reads.
    func testAProperlyRunTestIsNotFlaggedShort() throws {
        let result = try XCTUnwrap(HeartRateVariability.analyse(rrIntervalsMs: steady(seconds: 300, ms: 870)))
        XCTAssertTrue(result.isFrequencyDomainReliable)
    }
}
