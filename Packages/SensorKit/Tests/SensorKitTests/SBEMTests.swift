import Testing
import Foundation
@testable import SensorKit

@Test func chunkReaderRoundTripsSimpleChunks() throws {
    var bytes: [UInt8] = Array("SBEM0103".utf8)
    bytes += SBEMChunkReader.writeChunk(id: 5, payload: [1, 2, 3])
    bytes += SBEMChunkReader.writeChunk(id: 7, payload: [9, 9])

    let body = try SBEMChunkReader.stripHeaderAndValidate(Data(bytes))
    let chunks = try SBEMChunkReader.readChunks(body)

    #expect(chunks.count == 2)
    #expect(chunks[0].id == 5)
    #expect(chunks[0].payload == [1, 2, 3])
    #expect(chunks[1].id == 7)
    #expect(chunks[1].payload == [9, 9])
}

@Test func chunkReaderHandlesEscapedIdAndSize() throws {
    let bigPayload = [UInt8](repeating: 0x42, count: 300)
    var bytes: [UInt8] = Array("SBEM0103".utf8)
    bytes += SBEMChunkReader.writeChunk(id: 500, payload: bigPayload)

    let body = try SBEMChunkReader.stripHeaderAndValidate(Data(bytes))
    let chunks = try SBEMChunkReader.readChunks(body)

    #expect(chunks.count == 1)
    #expect(chunks[0].id == 500)
    #expect(chunks[0].payload.count == 300)
}

@Test func missingSBEMFourCCThrowsCompressedError() {
    let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
    #expect(throws: SBEMError.compressedDataNotSupported) {
        _ = try SBEMChunkReader.stripHeaderAndValidate(Data(bytes))
    }
}

@Test func descriptorTableExtractsIdAndPathFromTagLines() throws {
    var bytes: [UInt8] = Array("SBEM0103".utf8)
    bytes += SBEMChunkReader.writeChunk(id: 0, payload: SBEMChunkReaderTestHelpers.descriptorPayload(id: 3, lines: ["<PTH>/Meas/Acc/13", "<FRM>uint32"]))
    bytes += SBEMChunkReader.writeChunk(id: 0, payload: SBEMChunkReaderTestHelpers.descriptorPayload(id: 4, lines: ["<PTH>/Meas/HeartRate"]))

    let body = try SBEMChunkReader.stripHeaderAndValidate(Data(bytes))
    let chunks = try SBEMChunkReader.readChunks(body)
    let table = SBEMDescriptorTable(chunks: chunks)

    #expect(table.descriptors.count == 2)
    #expect(table.firstId(pathContains: "Acc") == 3)
    #expect(table.firstId(pathContains: "HeartRate") == 4)
}

@Test func logParserDecodesAccelAndHRSamples() throws {
    var descriptorBytes: [UInt8] = Array("SBEM0103".utf8)
    descriptorBytes += SBEMChunkReader.writeChunk(id: 0, payload: SBEMChunkReaderTestHelpers.descriptorPayload(id: 3, lines: ["<PTH>/Meas/Acc/13"]))
    descriptorBytes += SBEMChunkReader.writeChunk(id: 0, payload: SBEMChunkReaderTestHelpers.descriptorPayload(id: 4, lines: ["<PTH>/Meas/HeartRate"]))

    var logBytes: [UInt8] = Array("SBEM0103".utf8)
    logBytes += SBEMChunkReader.writeChunk(id: 3, payload: SBEMChunkReaderTestHelpers.accelPayload(timestampMs: 1_000, x: 2.5))
    logBytes += SBEMChunkReader.writeChunk(id: 4, payload: SBEMChunkReaderTestHelpers.hrPayload(average: 142.0))
    logBytes += SBEMChunkReader.writeChunk(id: 3, payload: SBEMChunkReaderTestHelpers.accelPayload(timestampMs: 1_100, x: -1.25))

    let result = try SBEMLogParser.parse(descriptorsData: Data(descriptorBytes), logData: Data(logBytes))

    #expect(result.accelSamples.count == 2)
    #expect(result.accelSamples[0] == .init(timestampMs: 1_000, x: 2.5))
    #expect(result.accelSamples[1] == .init(timestampMs: 1_100, x: -1.25))
    #expect(result.hrSamples.count == 1)
    #expect(result.hrSamples[0].averageBpm == 142.0)
}

@Test func debugDumpDoesNotThrowOnValidStream() throws {
    var bytes: [UInt8] = Array("SBEM0103".utf8)
    bytes += SBEMChunkReader.writeChunk(id: 3, payload: [1, 2, 3, 4])
    let description = SBEMDebugDump.describe(Data(bytes))
    #expect(description.contains("id=3"))
}

private enum SBEMChunkReaderTestHelpers {
    /// Builds a descriptor chunk payload per the format reverse-engineered
    /// from `sbem2json`: 2-byte little-endian id, then `\n`-joined tag lines.
    static func descriptorPayload(id: UInt16, lines: [String]) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF)]
        bytes += Array(lines.joined(separator: "\n").utf8)
        return bytes
    }

    static func accelPayload(timestampMs: UInt32, x: Float) -> [UInt8] {
        var bytes = withUnsafeBytes(of: timestampMs.littleEndian) { Array($0) }
        bytes += withUnsafeBytes(of: x.bitPattern.littleEndian) { Array($0) }
        return bytes
    }

    static func hrPayload(average: Float) -> [UInt8] {
        withUnsafeBytes(of: average.bitPattern.littleEndian) { Array($0) }
    }
}
