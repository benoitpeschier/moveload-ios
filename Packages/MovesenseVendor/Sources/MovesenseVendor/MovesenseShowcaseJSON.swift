import Foundation
import MoveLoadCore

/// Parses the JSON export files produced by the official Movesense Showcase
/// app (filenames like `<timestamp>_<serial>_acc_stream.json` /
/// `..._heartRate_stream.json`) — a workaround import path while `doPut`
/// against `Mem/DataLogger/*` remains broken on this device (see
/// `MovesenseSensorService.startLogging`), so recordings still have to be
/// made in Showcase rather than MoveLoad itself.
///
/// Confirmed against a real export
/// (2026-08-11): `{"data": [{"acc": {"Timestamp": <ms>, "ArrayAcc":
/// [{"x":…,"y":…,"z":…}, …]}}]}` for acceleration, `{"data":
/// [{"heartRate": {"average": <bpm>, "rrData": [<ms>]}}]}` for heart rate.
public enum MovesenseShowcaseJSON {
    /// The export filename's leading ISO8601-basic timestamp
    /// (`yyyyMMdd'T'HHmmss'Z'`), when parseable — else falls back to now.
    public static func startDate(fromFilename filename: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let prefix = filename.split(separator: "_").first, let date = formatter.date(from: String(prefix)) {
            return date
        }
        return Date()
    }

    /// True if this JSON's entries carry an `"acc"` key (as opposed to
    /// `"heartRate"`) — lets the caller sort two picked files without
    /// relying on filenames.
    public static func looksLikeAcceleration(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return false }
        return entries.contains { $0["acc"] != nil }
    }

    /// Returns all three axes: Z is the load signal, X and Y are needed for
    /// gait detection (see `GaitDetector`).
    public static func parseAcceleration(_ data: Data) throws -> (axes: AccelerationAxes, sampleRateHz: Double) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw SensorError.transferFailed(String(localized: "Format JSON Showcase non reconnu (clé \"data\" absente).", bundle: .module))
        }

        var accelX: [Double] = []
        var accelY: [Double] = []
        var accelZ: [Double] = []
        var firstTimestampMs: Double?
        var lastTimestampMs: Double?

        for entry in entries {
            guard let acc = entry["acc"] as? [String: Any],
                  let samples = acc["ArrayAcc"] as? [[String: Any]] else { continue }
            if let timestamp = (acc["Timestamp"] as? NSNumber)?.doubleValue {
                if firstTimestampMs == nil { firstTimestampMs = timestamp }
                lastTimestampMs = timestamp
            }
            for sample in samples {
                guard let x = (sample["x"] as? NSNumber)?.doubleValue,
                      let y = (sample["y"] as? NSNumber)?.doubleValue,
                      let z = (sample["z"] as? NSNumber)?.doubleValue else { continue }
                accelX.append(x)
                accelY.append(y)
                accelZ.append(z)
            }
        }

        guard !accelZ.isEmpty else {
            throw SensorError.transferFailed(String(localized: "Aucun échantillon d'accélération trouvé dans le fichier.", bundle: .module))
        }

        var sampleRateHz = 100.0
        if let first = firstTimestampMs, let last = lastTimestampMs, last > first {
            let elapsedSeconds = (last - first) / 1000
            sampleRateHz = Double(accelZ.count) / elapsedSeconds
        }

        return (AccelerationAxes(x: accelX, y: accelY, z: accelZ), sampleRateHz)
    }

    /// Showcase's heart-rate export carries no timestamp either, but it does
    /// carry `rrData` — the beat-to-beat intervals, which accumulate into the
    /// real timeline. Using the entry index as a one-second offset (as this
    /// used to) inflates zone durations by however far the heart rate sits
    /// from 60 bpm; see the matching note in `MovesenseSBEMDecoder`.
    public static func parseHeartRate(_ data: Data) throws -> [HRSample] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            return []
        }

        var elapsedMs = 0.0
        var samples: [HRSample] = []
        for entry in entries {
            guard let hr = entry["heartRate"] as? [String: Any],
                  let average = (hr["average"] as? NSNumber)?.doubleValue else { continue }
            let intervals = (hr["rrData"] as? [NSNumber])?.map(\.doubleValue).filter { $0 > 0 } ?? []
            let intervalMs = intervals.isEmpty
                ? (average > 0 ? 60_000 / average : 1_000)
                : intervals.reduce(0, +)
            elapsedMs += intervalMs
            samples.append(HRSample(timeOffset: elapsedMs / 1000, bpm: average))
        }
        return samples
    }
}
