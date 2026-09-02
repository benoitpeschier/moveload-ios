import XCTest
@testable import MoveLoadCore

/// Decoding pinned to bytes captured from the sensor on 2026-09-01. The layout
/// was read off the wire rather than assumed, and these are the actual
/// notifications — if the decode ever drifts, it drifts away from reality and
/// not merely away from an earlier opinion.
final class HeartRateStreamSampleTests: XCTestCase {

    private func sample(_ hex: String) -> HeartRateStreamSample? {
        HeartRateStreamSample(payload: Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }))
    }

    func testACapturedNotificationDecodes() throws {
        let s = try XCTUnwrap(sample("67 66 42 42 AD 05"))
        XCTAssertEqual(s.bpm, 48.6, accuracy: 0.01)
        XCTAssertEqual(s.rrIntervalsMs, [1453])
    }

    /// The averaged bpm and the interval describe the same heart, so they have
    /// to agree — a byte order mistake in either field would break that at once.
    func testTheAverageAndTheIntervalsAgree() throws {
        let captured = ["67 66 42 42 D2 04", "33 33 43 42 C2 04", "67 66 40 42 09 05",
                        "00 00 40 42 E9 04", "67 66 3E 42 01 05", "33 33 3B 42 F1 04"]
        for hex in captured {
            let s = try XCTUnwrap(sample(hex))
            let implied = 60_000.0 / Double(try XCTUnwrap(s.rrIntervalsMs.first))
            XCTAssertEqual(implied, s.bpm, accuracy: 3,
                           "\(hex): \(implied) bpm from the interval against \(s.bpm) reported")
        }
    }

    func testSeveralIntervalsInOneNotification() throws {
        // Not yet observed, but the whiteboard type is an array — reading them
        // all costs nothing and avoids dropping beats the day it batches.
        let s = try XCTUnwrap(sample("67 66 42 42 AD 05 D2 04"))
        XCTAssertEqual(s.rrIntervalsMs, [1453, 1234])
    }

    func testAPayloadTooShortIsRefused() {
        XCTAssertNil(sample("67 66 42"))
    }

    func testAnAverageWithNoIntervalsIsStillASample() throws {
        let s = try XCTUnwrap(sample("67 66 42 42"))
        XCTAssertEqual(s.bpm, 48.6, accuracy: 0.01)
        XCTAssertTrue(s.rrIntervalsMs.isEmpty)
    }
}
