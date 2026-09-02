import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// Runs the shipped analysis over a real exported session and prints what it
/// gets, so the app's figures can be checked against the same code rather than
/// against a Python reimplementation of it. Skipped unless the file is there,
/// which it will not be on anyone else's machine — the exports are athlete
/// data and stay out of the repository.
///
/// Set `MOVELOAD_PROBE_CSV` to a session export to use it.
final class RealSessionProbeTests: XCTestCase {

    func testPrintFiguresForARealSession() throws {
        guard let path = ProcessInfo.processInfo.environment["MOVELOAD_PROBE_CSV"],
              FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("MOVELOAD_PROBE_CSV not set")
        }

        let anchor = Double(ProcessInfo.processInfo.environment["MOVELOAD_PROBE_ANCHOR"] ?? "1.16") ?? 1.16
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let header = lines.removeFirst().split(separator: ",").map(String.init)

        func column(_ name: String) throws -> Int {
            guard let i = header.firstIndex(of: name) else {
                throw XCTSkip("column \(name) missing — need a triaxial export")
            }
            return i
        }
        let (ti, xi, yi, zi) = (try column("offset_s"), try column("accel_x"),
                                try column("accel_y"), try column("accel_z"))

        var times = [Double](), xs = [Double](), ys = [Double](), zs = [Double]()
        times.reserveCapacity(lines.count)
        for line in lines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count > max(ti, max(xi, max(yi, zi))),
                  let t = Double(f[ti]), let x = Double(f[xi]),
                  let y = Double(f[yi]), let z = Double(f[zi]) else { continue }
            times.append(t); xs.append(x); ys.append(y); zs.append(z)
        }
        guard times.count > 100 else { throw XCTSkip("too few rows") }

        // The rate the app stores comes from the logger's configuration; the
        // rate the samples actually arrived at is what the file says. They are
        // not the same, and the difference lands straight in every duration.
        var gaps = (1..<times.count).map { times[$0] - times[$0 - 1] }
        gaps.sort()
        let measuredRate = 1 / gaps[gaps.count / 2]

        // What the shipped curve makes of the session, so the anchor being
        // used is the one this code would offer rather than a script's.
        let probe = RawSessionData(
            startDate: .now, accelSampleRateHz: measuredRate,
            accelX: zs, axes: AccelerationAxes(x: xs, y: ys, z: zs), hrSamples: [])
        let curve = SessionAnalyzer.analyze(
            session: probe,
            settings: AnalysisSettings(hrThresholdLow: 130, hrThresholdHigh: 160,
                                       mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                                       confirmedMech45sAnchor: anchor)).curve
        print("\npics par fenetre :", MechanicalWindow.allCases
            .map { "\($0.seconds)s=" + (curve[$0].flatMap { $0 }.map { String(format: "%.2f", $0) } ?? "—") }
            .joined(separator: "  "))

        // Sweep the thresholds with the shipped chain, against this anchor.
        print("\nbalayage des seuils (ancre \(anchor)) :")
        for (lo, hi) in [(0.35, 0.55), (0.45, 0.70), (0.55, 0.80), (0.60, 0.90), (0.70, 1.00)] {
            let r = SessionAnalyzer.analyze(
                session: probe,
                settings: AnalysisSettings(hrThresholdLow: 130, hrThresholdHigh: 160,
                                           mechZonePercentLow: lo, mechZonePercentHigh: hi,
                                           confirmedMech45sAnchor: anchor))
            let a = r.mechZoneSeconds[.zone1] ?? 0, b = r.mechZoneSeconds[.zone2] ?? 0
            let c = r.mechZoneSeconds[.zone3] ?? 0
            print("  \(Int(lo*100))/\(Int(hi*100)) %   Z1 \(fmt(a))  Z2 \(fmt(b))  Z3 \(fmt(c))")
        }

        for rate in [measuredRate] {
            let raw = RawSessionData(
                startDate: .now,
                accelSampleRateHz: rate,
                accelX: zs,                       // the load axis on this mounting
                axes: AccelerationAxes(x: xs, y: ys, z: zs),
                hrSamples: []
            )
            let result = SessionAnalyzer.analyze(
                session: raw,
                settings: AnalysisSettings(
                    hrThresholdLow: 130, hrThresholdHigh: 160,
                    mechZonePercentLow: 0.35, mechZonePercentHigh: 0.55,
                    confirmedMech45sAnchor: anchor
                )
            )
            let z1 = result.mechZoneSeconds[.zone1] ?? 0
            let z2 = result.mechZoneSeconds[.zone2] ?? 0
            let z3 = result.mechZoneSeconds[.zone3] ?? 0
            let total = z1 + z2 + z3
            print("""

                --- \(String(format: "%.2f", rate)) Hz, ancre \(anchor) ---
                Z1 \(fmt(z1))   Z2 \(fmt(z2))   Z3 \(fmt(z3))   total \(fmt(total))
                parts \(pct(z1, total)) / \(pct(z2, total)) / \(pct(z3, total))
                au-dessus de l'ancre \(fmt(result.secondsAboveAnchor))
                marche exclue \(fmt(result.excludedWalkingSeconds)) · immobile \(fmt(result.inactiveSeconds))
                """)
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded())
        return "\(t / 60)'\(String(format: "%02d", t % 60))"
    }

    private func pct(_ part: Double, _ total: Double) -> String {
        total > 0 ? String(format: "%.1f%%", part / total * 100) : "—"
    }
}
