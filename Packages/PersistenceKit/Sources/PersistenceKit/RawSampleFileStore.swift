import Foundation
import MoveLoadCore

public enum PersistenceError: Error, Sendable {
    case corruptData
}

/// Raw accel/HR streams are stored as compact binary files rather than SwiftData
/// rows — a session can be tens/hundreds of thousands of samples, which is the
/// wrong shape for individual model rows (slow sequential reads, no relational
/// benefit since it's only ever read back as a contiguous time series).
public enum RawSampleFileStore {
    public static func write(_ data: RawSessionData, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var accelData = Data()
        var rate = Float32(data.accelSampleRateHz)
        withUnsafeBytes(of: &rate) { accelData.append(contentsOf: $0) }
        for value in data.accelX {
            var v = Float32(value)
            withUnsafeBytes(of: &v) { accelData.append(contentsOf: $0) }
        }
        try accelData.write(to: directory.appendingPathComponent("accel.bin"), options: .atomic)

        var hrData = Data()
        for sample in data.hrSamples {
            var offsetMs = UInt32(max(0, sample.timeOffset * 1000))
            var bpm = UInt16(max(0, min(65535, sample.bpm.rounded())))
            withUnsafeBytes(of: &offsetMs) { hrData.append(contentsOf: $0) }
            withUnsafeBytes(of: &bpm) { hrData.append(contentsOf: $0) }
        }
        try hrData.write(to: directory.appendingPathComponent("hr.bin"), options: .atomic)

        var dir = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
    }

    public static func read(startDate: Date, from directory: URL) throws -> RawSessionData {
        let accelFileData = try Data(contentsOf: directory.appendingPathComponent("accel.bin"))
        guard accelFileData.count >= 4 else { throw PersistenceError.corruptData }

        let rate = accelFileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float32.self) }
        let sampleCount = (accelFileData.count - 4) / 4
        var accel: [Double] = []
        accel.reserveCapacity(sampleCount)
        accelFileData.withUnsafeBytes { raw in
            for i in 0..<sampleCount {
                let v = raw.loadUnaligned(fromByteOffset: 4 + i * 4, as: Float32.self)
                accel.append(Double(v))
            }
        }

        var hr: [HRSample] = []
        if let hrFileData = try? Data(contentsOf: directory.appendingPathComponent("hr.bin")) {
            let entryCount = hrFileData.count / 6
            hrFileData.withUnsafeBytes { raw in
                for i in 0..<entryCount {
                    let offsetMs = raw.loadUnaligned(fromByteOffset: i * 6, as: UInt32.self)
                    let bpm = raw.loadUnaligned(fromByteOffset: i * 6 + 4, as: UInt16.self)
                    hr.append(HRSample(timeOffset: Double(offsetMs) / 1000, bpm: Double(bpm)))
                }
            }
        }

        return RawSessionData(startDate: startDate, accelSampleRateHz: Double(rate), accelX: accel, hrSamples: hr)
    }
}
