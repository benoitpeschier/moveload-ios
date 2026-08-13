import Foundation
import MoveLoadCore

/// Parses the JSON bodies returned by the MDS-level Logbook convenience
/// resources (`MDS/Logbook/<serial>/Entries` and
/// `MDS/Logbook/<serial>/ById/<id>/Data`).
///
/// **Honesty note**: the exact JSON shape of these convenience responses is
/// not documented anywhere in the device-lib or mobile-lib checkouts we
/// have — only that they exist and return "JSON format" (per
/// `Movesense/readme.txt`). The entry-list parsing below follows the
/// `LogEntry{Id,ModificationTimestamp,Size}` shape from the whiteboard's own
/// `logbook.yaml` (a reasonable bet, since MDS's JSON conversion likely
/// preserves the underlying resource's field names) with a couple of
/// casing fallbacks. The per-entry **data** parsing has no such reference
/// point at all — it throws a descriptive error surfacing the actual JSON
/// keys seen, rather than guessing a shape with no evidence, so the error
/// message itself becomes the debugging tool once real device data exists.
enum MovesenseLogbookJSON {
    static func parseEntries(_ body: [AnyHashable: Any]?) -> [LogbookEntryInfo] {
        guard let body = body as? [String: Any] else { return [] }
        let elements = firstArray(in: body, keys: ["elements", "Elements"])
            ?? firstDictionary(in: body, keys: ["Content"]).flatMap { firstArray(in: $0, keys: ["elements", "Elements"]) }
            ?? []

        return elements.compactMap { element -> LogbookEntryInfo? in
            guard let element = element as? [String: Any] else { return nil }
            guard let id = firstInt(in: element, keys: ["Id", "id"]) else { return nil }
            let timestamp = firstInt(in: element, keys: ["ModificationTimestamp", "modificationTimestamp"]) ?? 0
            let size = firstInt(in: element, keys: ["Size", "size"])
            return LogbookEntryInfo(
                id: String(id),
                startDate: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                duration: 0,
                sizeBytes: size
            )
        }
    }

    static func parseSessionData(_ body: [AnyHashable: Any]?, startDate: Date) throws -> RawSessionData {
        guard let body = body as? [String: Any] else { throw SensorError.transferFailed("Réponse Logbook vide") }
        let content = firstDictionary(in: body, keys: ["Content"]) ?? body

        guard let accelSamples = firstArray(in: content, keys: ["Meas/Acc", "Acc", "accel", "AccelerometerZ", "AccelerometerX"]) else {
            let keys = content.keys.sorted().joined(separator: ", ")
            throw SensorError.transferFailed(
                "Format JSON du Logbook MDS non reconnu — clés reçues: [\(keys)]. "
                    + "Le format exact n'a jamais été observé sur un vrai capteur ; "
                    + "utiliser ces clés pour corriger MovesenseLogbookJSON une fois des données réelles disponibles."
            )
        }
        let sampleRate = firstDouble(in: content, keys: ["SampleRate", "sampleRate"]) ?? 52.0

        // Z, not X: a first real-hardware test (Movesense Showcase app,
        // 2026-08-06) showed the effort-correlated signal on the sensor's Z
        // axis, not X as originally assumed from the torso-mounting guess.
        // Still a first impression, not a byte-level-verified capture — keep
        // watching the "format non reconnu" error below if this guess is wrong.
        let accelX: [Double] = accelSamples.compactMap { sample -> Double? in
            if let number = sample as? Double { return number }
            if let dict = sample as? [String: Any] { return firstDouble(in: dict, keys: ["z", "Z"]) }
            return nil
        }

        let hrSamples: [HRSample]
        if let hrArray = firstArray(in: content, keys: ["Meas/HR", "HR", "HeartRate"]) {
            hrSamples = hrArray.enumerated().compactMap { index, sample -> HRSample? in
                let bpm: Double?
                if let number = sample as? Double {
                    bpm = number
                } else if let dict = sample as? [String: Any] {
                    bpm = firstDouble(in: dict, keys: ["average", "Average"])
                } else {
                    bpm = nil
                }
                guard let bpm else { return nil }
                return HRSample(timeOffset: TimeInterval(index), bpm: bpm)
            }
        } else {
            hrSamples = []
        }

        return RawSessionData(startDate: startDate, accelSampleRateHz: sampleRate, accelX: accelX, hrSamples: hrSamples)
    }

    private static func firstArray(in dict: [String: Any], keys: [String]) -> [Any]? {
        for key in keys {
            if let array = dict[key] as? [Any] { return array }
        }
        return nil
    }

    private static func firstDictionary(in dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let nested = dict[key] as? [String: Any] { return nested }
        }
        return nil
    }

    private static func firstInt(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private static func firstDouble(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }
}
