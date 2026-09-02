import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// A PPG session — running, gym, circuits — read for its cardiac load alone.
/// Both exclusion passes are built for paddling: gait detection strips walking
/// and running, and inactivity detection strips the pauses. On a conditioning
/// session those *are* the session, so applying them would report a 45-minute
/// run as a few minutes of nothing.
final class ConditioningSessionTests: XCTestCase {

    private let fs = 52.8

    /// A run: a steady stride at 2.7 Hz, right inside the gait detector's band,
    /// with a minute standing still in the middle.
    private func run(seconds: Double) -> RawSessionData {
        let n = Int(seconds * fs)
        let pauseRange = (n / 2)..<(n / 2 + Int(60 * fs))
        var x = [Double](), y = [Double](), z = [Double]()
        for i in 0..<n {
            let t = Double(i) / fs
            let stride = pauseRange.contains(i) ? 0 : sin(2 * .pi * 2.7 * t)
            x.append(stride * 3);  y.append(0.4 * stride);  z.append(9.81 + stride * 2)
        }
        let hr = (0..<Int(seconds)).map { HRSample(timeOffset: Double($0), bpm: 150) }
        return RawSessionData(startDate: .now, accelSampleRateHz: fs, accelX: z,
                              axes: AccelerationAxes(x: x, y: y, z: z), hrSamples: hr)
    }

    private func analyse(_ raw: RawSessionData, isConditioning: Bool) -> SessionAnalysisResult {
        SessionAnalyzer.analyze(
            session: raw,
            settings: AnalysisSettings(hrThresholdLow: 130, hrThresholdHigh: 160,
                                       mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                                       confirmedMech45sAnchor: 1.58),
            isConditioning: isConditioning)
    }

    func testNothingIsExcludedFromAConditioningSession() {
        let result = analyse(run(seconds: 1800), isConditioning: true)
        XCTAssertEqual(result.excludedWalkingSeconds, 0, "the running is the session")
        XCTAssertEqual(result.inactiveSeconds, 0, "and so is the pause in the middle")
    }

    /// The whole half hour lands in a heart-rate zone, pause included.
    func testCardiacLoadCoversTheWholeRecording() {
        let result = analyse(run(seconds: 1800), isConditioning: true)
        let counted = HRZone.allCases.reduce(0.0) { $0 + (result.hrZoneSeconds[$1] ?? 0) }
        XCTAssertEqual(counted, 1800, accuracy: 5)
        XCTAssertEqual(result.hrZoneSeconds[.i2] ?? 0, 1800, accuracy: 5, "150 bpm, between 130 and 160")
    }

    /// The point of the flag. Chest acceleration while running is stride, and
    /// a stride peak dwarfs anything produced on the water — left in, it would
    /// become the athlete's 45 s reference and rewrite every zone in the app.
    func testNoMechanicalFigureIsProduced() {
        let result = analyse(run(seconds: 1800), isConditioning: true)
        XCTAssertTrue(result.mechZoneSeconds.isEmpty)
        XCTAssertEqual(result.secondsAboveAnchor, 0)
        XCTAssertEqual(result.mechZoneAnchorUsed, 0)
        XCTAssertTrue(result.curve.compactMap { $0.value }.isEmpty,
                      "no curve means nothing for the record queries to find")
    }

    /// The same recording read as paddling: the exclusions fire, and there is
    /// a curve. Without this the test above would pass on a broken analyser
    /// that produced nothing for any session at all.
    func testTheSameRecordingReadAsPaddlingIsTreatedDifferently() {
        let result = analyse(run(seconds: 1800), isConditioning: false)
        XCTAssertGreaterThan(result.excludedWalkingSeconds + result.inactiveSeconds, 55,
                             "gait and inactivity both have something to say here")
        XCTAssertFalse(result.curve.compactMap { $0.value }.isEmpty)
    }
}
