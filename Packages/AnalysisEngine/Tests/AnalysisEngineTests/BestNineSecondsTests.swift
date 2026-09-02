import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// The stroke waveform shown to the coach: the effort signal over the athlete's
/// best nine seconds. Every other figure the analyser produces is a total or a
/// peak; this is the only one that carries a shape, and a shape taken from the
/// wrong nine seconds would be worse than none — it would look authoritative
/// and describe a different moment of the session.
final class BestNineSecondsTests: XCTestCase {

    private let fs = 50.0

    /// Quiet paddling throughout, with one loud burst placed on purpose.
    private func session(burstAt seconds: Double, burstLength: Double = 9) -> RawSessionData {
        let total = Int(180 * fs)
        let accel = (0..<total).map { i -> Double in
            let t = Double(i) / fs
            let loud = t >= seconds && t < seconds + burstLength
            let phase = t * (80.0 / 60)
            let u = phase - phase.rounded(.down)
            let amplitude = loud ? 6.0 : 1.5
            return u < 0.45 ? amplitude * sin(.pi * u / 0.45) : 0
        }
        return RawSessionData(startDate: .now, accelSampleRateHz: fs, accelX: accel, hrSamples: [])
    }

    private func analyse(_ raw: RawSessionData) -> SessionAnalysisResult {
        SessionAnalyzer.analyze(
            session: raw,
            settings: AnalysisSettings(hrThresholdLow: 130, hrThresholdHigh: 160,
                                       mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                                       confirmedMech45sAnchor: 2.0))
    }

    func testItIsNineSecondsLongAtTheSessionRate() {
        let result = analyse(session(burstAt: 60))
        XCTAssertEqual(result.bestNineSecondsRateHz, fs)
        XCTAssertEqual(Double(result.bestNineSecondsSignal.count) / result.bestNineSecondsRateHz,
                       9, accuracy: 0.05)
    }

    /// The slice must come from where the peak actually is. A burst at 60 s and
    /// one at 120 s are indistinguishable by their peak *value*, so only the
    /// position tells them apart.
    func testItComesFromTheLoudStretchAndNotElsewhere() {
        let result = analyse(session(burstAt: 60))
        let mean = result.bestNineSecondsSignal.map { max(0, $0) }.reduce(0, +)
            / Double(result.bestNineSecondsSignal.count)
        let peak9 = try? XCTUnwrap(result.curve[.s9] ?? nil)

        XCTAssertEqual(mean, peak9 ?? 0, accuracy: 0.05,
                       "the slice's own mean is the 9 s peak, or it is the wrong slice")
    }

    func testAShortSessionYieldsNoWaveformRatherThanAPartialOne() {
        let raw = RawSessionData(
            startDate: .now, accelSampleRateHz: fs,
            accelX: [Double](repeating: 3, count: Int(5 * fs)), hrSamples: [])
        let result = analyse(raw)
        XCTAssertTrue(result.bestNineSecondsSignal.isEmpty)
        XCTAssertEqual(result.bestNineSecondsRateHz, 0)
    }
}
