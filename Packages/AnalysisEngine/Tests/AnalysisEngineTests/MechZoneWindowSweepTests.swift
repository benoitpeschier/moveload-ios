import XCTest
import MoveLoadCore
@testable import AnalysisEngine

/// Compares averaging windows on real sessions, so the choice of window rests
/// on what the athlete's own recordings do rather than on intuition about how
/// long a sprint is. Skipped unless the exports are present — they are athlete
/// data and stay out of the repository.
///
/// Set `MOVELOAD_PROBE_DIR` to the folder holding `session_*_accel.csv`.
final class MechZoneWindowSweepTests: XCTestCase {

    private let windows: [Double] = [10, 15, 30]
    private let anchor = Double(ProcessInfo.processInfo.environment["MOVELOAD_PROBE_ANCHOR"] ?? "1.58") ?? 1.58

    func testCompareWindowsOnRealSessions() throws {
        guard let directory = ProcessInfo.processInfo.environment["MOVELOAD_PROBE_DIR"] else {
            throw XCTSkip("MOVELOAD_PROBE_DIR not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("session_") && $0.hasSuffix("_accel.csv") }
            .sorted()
        guard !files.isEmpty else { throw XCTSkip("no session exports in \(directory)") }

        print("\n=== ancre \(anchor) m/s², seuils 35 / 55 % ===")

        for file in files {
            let name = String(file.dropFirst("session_".count).prefix(8))
            let (raw, rate) = try load(directory + "/" + file)

            // The kept signal, from the shipped chain: gravity removed, walking
            // and standing still excluded. Everything below reads this, so the
            // windows are compared on identical input.
            let prepared = SessionAnalyzer.prepared(session: raw)

            print("\n--- \(name)  (\(String(format: "%.1f", rate)) Hz, \(fmt(Double(prepared.signal.count) / rate)) enregistrées) ---")
            print("  au-dessus de l'ancre (signal brut, sans fenêtre) : \(fmt(ZoneTimeAccumulator.secondsAboveAnchor(accelX: prepared.signal, sampleRateHz: rate, anchor: anchor, keepMask: prepared.keepMask)))")

            for window in windows {
                let z = ZoneTimeAccumulator.mechZoneSeconds(
                    accelX: prepared.signal, sampleRateHz: rate,
                    thresholdLow: anchor * 0.35, thresholdHigh: anchor * 0.55,
                    keepMask: prepared.keepMask, windowSeconds: window)
                let z1 = z[.zone1] ?? 0, z2 = z[.zone2] ?? 0, z3 = z[.zone3] ?? 0
                let total = z1 + z2 + z3

                // What the mean itself reaches, as a share of the anchor. This
                // is what decides whether the percentages still fit: a shorter
                // window smooths less, so the same thresholds sit lower on the
                // distribution and zone 3 fills whether or not the effort changed.
                let means = rollingMeans(prepared.signal, rate: rate,
                                         window: window, mask: prepared.keepMask).sorted()
                func q(_ p: Double) -> String {
                    means.isEmpty ? "—" : String(format: "%.0f %%", 100 * means[min(means.count - 1, Int(p * Double(means.count)))] / anchor)
                }

                print("  \(Int(window)) s   Z1 \(fmt(z1))  Z2 \(fmt(z2))  Z3 \(fmt(z3))"
                      + "   parts \(pct(z1, total))/\(pct(z2, total))/\(pct(z3, total))"
                      + "   moyenne p50 \(q(0.5))  p90 \(q(0.9))  max \(q(0.999))")
            }
        }
    }

    // MARK: -

    private func rollingMeans(_ signal: [Double], rate: Double, window: Double, mask: [Bool]?) -> [Double] {
        let n = max(1, Int((window * rate).rounded()))
        var out = [Double](); out.reserveCapacity(signal.count)
        var sum = 0.0, kept = 0, head = 0
        for i in signal.indices {
            while head < signal.count && head < i + n / 2 + 1 {
                if mask?[head] ?? true { sum += max(0, signal[head]); kept += 1 }
                head += 1
            }
            let tail = i - (n - n / 2)
            if tail >= 0, mask?[tail] ?? true { sum -= max(0, signal[tail]); kept -= 1 }
            guard mask?[i] ?? true, kept > 0 else { continue }
            out.append(sum / Double(kept))
        }
        return out
    }

    private func load(_ path: String) throws -> (RawSessionData, Double) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        func column(_ name: String) throws -> Int {
            guard let i = header.firstIndex(of: name) else { throw XCTSkip("column \(name) missing") }
            return i
        }
        let (ti, xi, yi, zi) = (try column("offset_s"), try column("accel_x"),
                                try column("accel_y"), try column("accel_z"))

        var times = [Double](), xs = [Double](), ys = [Double](), zs = [Double]()
        for line in lines {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count > max(ti, max(xi, max(yi, zi))),
                  let t = Double(f[ti]), let x = Double(f[xi]),
                  let y = Double(f[yi]), let z = Double(f[zi]) else { continue }
            times.append(t); xs.append(x); ys.append(y); zs.append(z)
        }
        var gaps = (1..<times.count).map { times[$0] - times[$0 - 1] }
        gaps.sort()
        let rate = 1 / gaps[gaps.count / 2]
        return (RawSessionData(startDate: .now, accelSampleRateHz: rate,
                               accelX: zs, axes: AccelerationAxes(x: xs, y: ys, z: zs),
                               hrSamples: []), rate)
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded())
        return "\(t / 60)'\(String(format: "%02d", t % 60))"
    }

    private func pct(_ part: Double, _ total: Double) -> String {
        total > 0 ? String(format: "%.0f", part / total * 100) : "—"
    }
}
