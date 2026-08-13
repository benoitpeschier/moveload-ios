import Foundation
import MoveLoadCore

/// Parses the JSON export files produced by the official Movesense Showcase
/// app (filenames like `<timestamp>_<serial>_acc_stream.json` /
/// `..._heartRate_stream.json`) — a workaround import path while `doPut`
/// against `Mem/DataLogger/*` remains broken on this device (see
/// `MovesenseSensorService.startLogging`), so recordings still have to be
/// made in Showcase rather than MoveLoad itself.
///
/// This is a different, app-specific export shape from the MDS Logbook JSON
/// `MovesenseLogbookJSON` decodes. Confirmed against a real export
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

    public static func parseAcceleration(_ data: Data) throws -> (accelZ: [Double], sampleRateHz: Double) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw SensorError.transferFailed("Format JSON Showcase non reconnu (clé \"data\" absente).")
        }

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
                guard let z = (sample["z"] as? NSNumber)?.doubleValue else { continue }
                accelZ.append(z)
            }
        }

        guard !accelZ.isEmpty else {
            throw SensorError.transferFailed("Aucun échantillon d'accélération trouvé dans le fichier.")
        }

        var sampleRateHz = 100.0
        if let first = firstTimestampMs, let last = lastTimestampMs, last > first {
            let elapsedSeconds = (last - first) / 1000
            sampleRateHz = Double(accelZ.count) / elapsedSeconds
        }

        return (accelZ, sampleRateHz)
    }

    /// Showcase's heart-rate export has no per-sample timestamp, only an
    /// implicit ordering — matches `MovesenseLogbookJSON`'s own convention
    /// of treating the entry index as a one-second offset (an approximation,
    /// not the true per-beat timing).
    public static func parseHeartRate(_ data: Data) throws -> [HRSample] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            return []
        }
        return entries.enumerated().compactMap { index, entry -> HRSample? in
            guard let hr = entry["heartRate"] as? [String: Any],
                  let average = (hr["average"] as? NSNumber)?.doubleValue else { return nil }
            return HRSample(timeOffset: TimeInterval(index), bpm: average)
        }
    }
}
