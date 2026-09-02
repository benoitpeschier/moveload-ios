import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// What the averaging window does to efforts shorter than itself.
///
/// The real sessions available contain nothing shorter than ~24 s, so the
/// question "does a shorter window catch sprints" cannot be answered from
/// them. The answer is not the intuitive one: a window longer than the effort
/// does not *miss* it, it *smears* it — the mean stays above the threshold
/// either side of the sprint, and zone 3 comes out longer than the sprint was.
final class SprintWindowTests: XCTestCase {

    private let fs = 52.8
    private let anchor = 1.58

    /// Repetitions at `level` × anchor with rest at 15 %, a 1:3 work:rest duty.
    private func repetitions(effortSeconds: Double, level: Double, count: Int) -> [Double] {
        var out = [Double]()
        for _ in 0..<count {
            out += [Double](repeating: anchor * level, count: Int(effortSeconds * fs))
            out += [Double](repeating: anchor * 0.15, count: Int(effortSeconds * 3 * fs))
        }
        return out
    }

    private func zone3(_ signal: [Double], window: Double) -> TimeInterval {
        ZoneTimeAccumulator.mechZoneSeconds(
            accelX: signal, sampleRateHz: fs,
            thresholdLow: anchor * 0.35, thresholdHigh: anchor * 0.55,
            windowSeconds: window)[.zone3] ?? 0
    }

    /// Ten 8 s sprints at 1.5 × the anchor: 80 s of hard work.
    func testAShortWindowIsCloserToTheEffortActuallyDone() {
        let signal = repetitions(effortSeconds: 8, level: 1.5, count: 10)

        let short = zone3(signal, window: 10)
        let shipped = zone3(signal, window: 15)

        XCTAssertGreaterThan(short, 80, "the sprints are found either way")
        XCTAssertLessThan(short, shipped, "but the longer window spreads them over more time")
        XCTAssertLessThan(shipped / short, 1.3, "the gap is real and modest, not a different verdict")
    }

    /// The failure mode that fixed the window at 15 s rather than 30 s: at a
    /// 1:3 duty the 30 s mean of an 8 s sprint is (8×1.5 + 22×0.15)/30 = 0.51 of
    /// the anchor — just under the 0.55 threshold, so a session of ten sprints
    /// reads as almost no hard work at all.
    func testALongWindowCanLoseASprintEntirely() {
        let signal = repetitions(effortSeconds: 8, level: 1.5, count: 10)
        XCTAssertLessThan(zone3(signal, window: 30), 30, "80 s of sprinting, all but erased")
        XCTAssertGreaterThan(zone3(signal, window: 15), 100, "which 15 s does not do")
    }

    /// Whatever the window does to the zones, this figure is untouched by it —
    /// which is why it is reported separately.
    func testSecondsAboveTheAnchorDoNotDependOnAnyWindow() {
        let signal = repetitions(effortSeconds: 8, level: 1.5, count: 10)
        let above = ZoneTimeAccumulator.secondsAboveAnchor(
            accelX: signal, sampleRateHz: fs, anchor: anchor)
        XCTAssertEqual(above, 80, accuracy: 2, "ten sprints of eight seconds, counted as such")
    }
}
