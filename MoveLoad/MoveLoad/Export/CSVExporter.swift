import Foundation
import PersistenceKit
import MoveLoadCore

enum CSVExporter {
    static func exportSession(_ session: Session) throws -> [URL] {
        let sessionDirectory = PersistenceContainer.documentsSessionsDirectory()
            .appendingPathComponent(session.rawSampleDirectory)
        let raw = try RawSampleFileStore.read(startDate: session.startDate, from: sessionDirectory)
        let tempDirectory = FileManager.default.temporaryDirectory
        let idPrefix = session.id.uuidString

        let accelURL = tempDirectory.appendingPathComponent("session_\(idPrefix)_accel.csv")
        try accelCSV(for: raw).write(to: accelURL, atomically: true, encoding: .utf8)

        let hrURL = tempDirectory.appendingPathComponent("session_\(idPrefix)_hr.csv")
        var hrCSV = "offset_s,bpm\n"
        for sample in raw.hrSamples {
            hrCSV += "\(sample.timeOffset),\(sample.bpm)\n"
        }
        try hrCSV.write(to: hrURL, atomically: true, encoding: .utf8)

        let summaryURL = tempDirectory.appendingPathComponent("session_\(idPrefix)_summary.csv")
        try summaryCSV(for: [session]).write(to: summaryURL, atomically: true, encoding: .utf8)

        return [summaryURL, accelURL, hrURL]
    }

    static func exportAllSessionsSummary(_ sessions: [Session]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("all_sessions_summary.csv")
        try summaryCSV(for: sessions).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// All three axes when the session has them, so the recording can be
    /// re-analysed outside the app — gait detection needs the full vector, and
    /// a single-axis export could not reproduce it. Sessions imported before
    /// triaxial storage only carry the load axis, and say so in the header
    /// rather than padding the missing columns with zeros.
    ///
    /// `accel_z` is deliberately the name of the load axis: the old header
    /// called it `accel_x`, which named the wrong physical axis.
    private static func accelCSV(for raw: RawSessionData) -> String {
        let dt = 1.0 / raw.accelSampleRateHz

        guard let axes = raw.axes, axes.count == raw.accelX.count else {
            var csv = "offset_s,accel_z\n"
            for (index, value) in raw.accelX.enumerated() {
                csv += "\(Double(index) * dt),\(value)\n"
            }
            return csv
        }

        var csv = "offset_s,accel_x,accel_y,accel_z\n"
        for index in 0..<axes.count {
            csv += "\(Double(index) * dt),\(axes.x[index]),\(axes.y[index]),\(axes.z[index])\n"
        }
        return csv
    }

    /// Quotes a free-text field so a comma, quote or newline typed into a
    /// session name can't shift every following column.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func summaryCSV(for sessions: [Session]) -> String {
        var csv = "date,name,duration_s,boat_type,is_test,perceived_exertion,excluded_walking_s,hr_zone_i1_s,hr_zone_i2_s,hr_zone_i3_s,mech_zone_1_s,mech_zone_2_s,mech_zone_3_s"
        for window in MechanicalWindow.allCases {
            csv += ",peak_\(Int(window.seconds))s"
        }
        csv += "\n"

        let dateFormatter = ISO8601DateFormatter()
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            csv += "\(dateFormatter.string(from: session.startDate))"
            csv += ",\(csvField(session.name ?? ""))"
            csv += ",\(session.duration)"
            csv += ",\(session.boatType?.rawValue ?? "")"
            csv += ",\(session.isTest)"
            csv += ",\(session.perceivedExertion.map(String.init) ?? "")"
            csv += ",\(session.excludedWalkingSeconds)"
            csv += ",\(session.hrZoneI1Seconds),\(session.hrZoneI2Seconds),\(session.hrZoneI3Seconds)"
            csv += ",\(session.mechZone1Seconds),\(session.mechZone2Seconds),\(session.mechZone3Seconds)"
            for window in MechanicalWindow.allCases {
                let point = session.curvePoints.first { $0.window == window }
                csv += ",\(point?.peakValue.map { String($0) } ?? "")"
            }
            csv += "\n"
        }
        return csv
    }
}
