import XCTest
@testable import AnalysisEngine

/// The cascade is a coach's clinical rules, transcribed. These tests exist to
/// keep the transcription honest: each threshold is checked on both sides, and
/// the ordering is checked where two patterns would otherwise both fire.
final class FatiguePatternsTests: XCTestCase {

    private typealias P = FatiguePatterns.Pattern

    private func deltas(hfSu: Double = 0, lfSu: Double = 0,
                        hfSt: Double = 0, lfSt: Double = 0,
                        smallBase: Bool = false) -> FatiguePatterns.Deltas {
        .init(hfSupine: hfSu, lfSupine: lfSu, hfStanding: hfSt,
              lfStanding: lfSt, restsOnSmallBase: smallBase)
    }

    // MARK: - Each rule, on both sides of its thresholds

    func testEnergyCollapseNeedsBothConditions() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: -60, lfSt: -40)), .energyCollapse)
        // −48 and −30 are the boundaries; at them, nothing fires.
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: -48, lfSt: -40)))
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: -60, lfSt: -30)))
    }

    func testAcuteStress() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(lfSu: 90, lfSt: -75)), .acuteStress)
        XCTAssertNil(FatiguePatterns.evaluate(deltas(lfSu: 80, lfSt: -75)))
    }

    func testActivationBrake() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: -60, hfSt: 250)), .activationBrake)
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: -60, hfSt: 200)))
    }

    func testExtremeFatigue() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: 600)), .extremeFatigue)
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: 500)))
    }

    func testPeripheralRegulation() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(lfSt: -85)), .peripheralRegulation)
        XCTAssertNil(FatiguePatterns.evaluate(deltas(lfSt: -80)))
    }

    func testNoPatternIsTheOrdinaryCase() {
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: 5, lfSu: -10, hfSt: 20, lfSt: -15)))
    }

    // MARK: - Order

    /// Energy collapse and peripheral regulation both match a large LF drop
    /// standing. The cascade must give the first, which is the graver reading.
    func testTheFirstMatchWinsOverALaterOne() {
        let both = deltas(hfSu: -60, lfSt: -85)
        XCTAssertEqual(FatiguePatterns.evaluate(both), .energyCollapse)
    }

    /// Extreme fatigue sits *after* the activation brake, so a test satisfying
    /// both is reported as the brake. Reordering the cascade would silently
    /// change what the coach is told.
    func testActivationBrakeTakesPrecedenceOverExtremeFatigue() {
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: -60, hfSt: 250)), .activationBrake)
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: 600, hfSt: 250)), .extremeFatigue)
    }

    // MARK: - Deltas

    func testPercentChange() {
        XCTAssertEqual(FatiguePatterns.percentChange(from: 100, to: 150), 50)
        XCTAssertEqual(FatiguePatterns.percentChange(from: 100, to: 40), -60)
    }

    /// A reference of zero has no percentage. Returning a huge number instead
    /// would fire the +500 % rule on the first test after a failed one.
    func testAZeroReferenceHasNoPercentage() {
        XCTAssertNil(FatiguePatterns.percentChange(from: 0, to: 150))
    }

    /// The workbook's own example: HF standing rising from about 16 to about
    /// 146 ms², which it reports as +807 %. On those two rounded figures the
    /// arithmetic gives 812.5 — the workbook's percentage came from unrounded
    /// values. What matters here is not the third digit but that a change of
    /// this size, resting on 16 ms², is mostly arithmetic and must be flagged.
    func testASmallBaseIsFlaggedNotHidden() throws {
        let d = try XCTUnwrap(FatiguePatterns.deltas(
            currentSupine: .init(lf: 900, hf: 800),
            currentStanding: .init(lf: 700, hf: 146),
            referenceSupine: .init(lf: 850, hf: 820),
            referenceStanding: .init(lf: 690, hf: 16)))

        XCTAssertEqual(d.hfStanding, 812.5, accuracy: 0.5)
        XCTAssertTrue(d.restsOnSmallBase, "16 ms² is not a base a percentage can rest on")
    }

    func testAnOrdinaryReferenceIsNotFlagged() throws {
        let d = try XCTUnwrap(FatiguePatterns.deltas(
            currentSupine: .init(lf: 900, hf: 800),
            currentStanding: .init(lf: 700, hf: 300),
            referenceSupine: .init(lf: 850, hf: 820),
            referenceStanding: .init(lf: 690, hf: 280)))
        XCTAssertFalse(d.restsOnSmallBase)
    }

    /// Thresholds are settings, not constants — a squad may need to move them.
    func testThresholdsCanBeMoved() {
        var relaxed = FatiguePatterns.Thresholds()
        relaxed.extremeFatigueHFSupine = 300
        XCTAssertNil(FatiguePatterns.evaluate(deltas(hfSu: 400)))
        XCTAssertEqual(FatiguePatterns.evaluate(deltas(hfSu: 400), thresholds: relaxed), .extremeFatigue)
    }

    func testEveryPatternHasAReadingAndNoneRecommendsATraining() {
        for pattern in P.allCases {
            XCTAssertFalse(pattern.reading.isEmpty)
            let lowered = pattern.reading.lowercased()
            for prescriptive in ["repos", "récup", "entraîne", "séance", "charge"] {
                XCTAssertFalse(lowered.contains(prescriptive),
                               "\(pattern.rawValue) prescribes rather than describes")
            }
        }
    }
}
