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
        var accelCSV = "offset_s,accel_x\n"
        let dt = 1.0 / raw.accelSampleRateHz
        for (index, value) in raw.accelX.enumerated() {
            accelCSV += "\(Double(index) * dt),\(value)\n"
        }
        try accelCSV.write(to: accelURL, atomically: true, encoding: .utf8)

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

    private static func summaryCSV(for sessions: [Session]) -> String {
        var csv = "date,duration_s,boat_type,perceived_exertion,hr_zone_i1_s,hr_zone_i2_s,hr_zone_i3_s,mech_zone_1_s,mech_zone_2_s,mech_zone_3_s"
        for window in MechanicalWindow.allCases {
            csv += ",peak_\(Int(window.seconds))s"
        }
        csv += "\n"

        let dateFormatter = ISO8601DateFormatter()
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            csv += "\(dateFormatter.string(from: session.startDate)),\(session.duration)"
            csv += ",\(session.boatType?.rawValue ?? "")"
            csv += ",\(session.perceivedExertion.map(String.init) ?? "")"
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
