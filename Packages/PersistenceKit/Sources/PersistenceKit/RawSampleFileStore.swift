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
    /// Leading marker for the triaxial layout. Version 1 files have no magic
    /// and open directly with a Float32 sample rate, so the two are told
    /// apart by looking for these bytes — a v1 rate could never encode them
    /// (as a Float32 they read as ~5.5e12, not a plausible sample rate).
    private static let magicV2 = Array("MLA2".utf8)

    public static func write(_ data: RawSessionData, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var accelData = Data()
        if let axes = data.axes {
            // v2: magic + rate + count, then x, y and z back to back.
            accelData.append(contentsOf: magicV2)
            var rate = Float32(data.accelSampleRateHz)
            var count = Int32(axes.count)
            withUnsafeBytes(of: &rate) { accelData.append(contentsOf: $0) }
            withUnsafeBytes(of: &count) { accelData.append(contentsOf: $0) }
            for axis in [axes.x, axes.y, axes.z] {
                for i in 0..<Int(count) {
                    var v = Float32(axis[i])
                    withUnsafeBytes(of: &v) { accelData.append(contentsOf: $0) }
                }
            }
        } else {
            var rate = Float32(data.accelSampleRateHz)
            withUnsafeBytes(of: &rate) { accelData.append(contentsOf: $0) }
            for value in data.accelX {
                var v = Float32(value)
                withUnsafeBytes(of: &v) { accelData.append(contentsOf: $0) }
            }
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

        let rate: Float32
        var accel: [Double] = []
        var axes: AccelerationAxes?

        if accelFileData.count >= 12, accelFileData.prefix(4).elementsEqual(magicV2) {
            rate = accelFileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float32.self) }
            let count = Int(accelFileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int32.self) })
            guard count >= 0, accelFileData.count >= 12 + count * 12 else { throw PersistenceError.corruptData }
            var parsed: [[Double]] = []
            accelFileData.withUnsafeBytes { raw in
                for axisIndex in 0..<3 {
                    var values: [Double] = []
                    values.reserveCapacity(count)
                    let base = 12 + axisIndex * count * 4
                    for i in 0..<count {
                        values.append(Double(raw.loadUnaligned(fromByteOffset: base + i * 4, as: Float32.self)))
                    }
                    parsed.append(values)
                }
            }
            axes = AccelerationAxes(x: parsed[0], y: parsed[1], z: parsed[2])
            accel = parsed[2]
        } else {
            rate = accelFileData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float32.self) }
            let sampleCount = (accelFileData.count - 4) / 4
            accel.reserveCapacity(sampleCount)
            accelFileData.withUnsafeBytes { raw in
                for i in 0..<sampleCount {
                    let v = raw.loadUnaligned(fromByteOffset: 4 + i * 4, as: Float32.self)
                    accel.append(Double(v))
                }
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

        return RawSessionData(
            startDate: startDate,
            accelSampleRateHz: Double(rate),
            accelX: accel,
            axes: axes,
            hrSamples: hr
        )
    }
}
