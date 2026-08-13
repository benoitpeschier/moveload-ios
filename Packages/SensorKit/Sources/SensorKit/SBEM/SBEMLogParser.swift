import Foundation

/// Decodes accelerometer Z and heart-rate samples out of a Movesense
/// logbook entry's SBEM data stream.
///
/// Scope note: MoveLoad only needs accel **Z** — not X as originally assumed
/// from the torso-mounting guess; a first real-hardware test (Movesense
/// Showcase app, 2026-08-06) showed the effort-correlated signal on Z instead
/// — and HR **average**, so this deliberately does not decode the full
/// `MovesenseAcc { timestamp, vectors: [Vector3D] }` / `MovesenseHeartRate
/// { average, rrData }` shapes (known from the live-measurement Swift API)
/// — it reads only the relevant bytes of each value chunk:
///   - Accel chunk payload assumed to be `timestamp: UInt32 LE` then a single
///     `Vector3D` (`x, y: Float32 LE` skipped, `z: Float32 LE` read).
///   - HR chunk payload assumed to start with `average: Float32 LE`
///     (`rrData`, if present, is ignored).
/// The device-lib docs note the DataLogger "only stores the 1st element of
/// an array" — relevant if the live accel resource batches multiple vectors
/// per notification, since only one would end up logged per chunk. This
/// affects the *effective* sample rate of downloaded data and should be
/// checked against real timestamps once available, rather than trusting the
/// configured Hz value blindly.
public enum SBEMLogParser {
    public struct AccelSample: Sendable, Equatable {
        public let timestampMs: UInt32
        public let z: Float
    }

    public struct HRSampleRaw: Sendable, Equatable {
        public let averageBpm: Float
    }

    public struct ParsedLog: Sendable {
        public let accelSamples: [AccelSample]
        public let hrSamples: [HRSampleRaw]
    }

    public static func parse(descriptorsData: Data, logData: Data) throws -> ParsedLog {
        let descriptorBytes = try SBEMChunkReader.stripHeaderAndValidate(descriptorsData)
        let descriptorChunks = try SBEMChunkReader.readChunks(descriptorBytes)
        let table = SBEMDescriptorTable(chunks: descriptorChunks)

        let logBytes = try SBEMChunkReader.stripHeaderAndValidate(logData)
        let logChunks = try SBEMChunkReader.readChunks(logBytes)

        let accelId = table.firstId(pathContains: "Acc")
        let hrId = table.firstId(pathContains: "HeartRate") ?? table.firstId(pathContains: "/HR")

        var accel: [AccelSample] = []
        var hr: [HRSampleRaw] = []

        for chunk in logChunks {
            if let accelId, chunk.id == accelId, chunk.payload.count >= 16 {
                let timestamp = readUInt32LE(chunk.payload, 0)
                let z = readFloat32LE(chunk.payload, 12)
                accel.append(AccelSample(timestampMs: timestamp, z: z))
            } else if let hrId, chunk.id == hrId, chunk.payload.count >= 4 {
                let average = readFloat32LE(chunk.payload, 0)
                hr.append(HRSampleRaw(averageBpm: average))
            }
        }

        return ParsedLog(accelSamples: accel, hrSamples: hr)
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readFloat32LE(_ bytes: [UInt8], _ offset: Int) -> Float {
        Float(bitPattern: readUInt32LE(bytes, offset))
    }
}
