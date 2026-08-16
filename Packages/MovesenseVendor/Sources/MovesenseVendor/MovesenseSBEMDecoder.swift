import Foundation
import MoveLoadCore

/// Decodes the raw SBEM bytes `MovesenseGSPClient.fetchLog` returns into
/// `RawSessionData`.
///
/// Reverse-engineered byte-for-byte against a real recording (2026-08-13),
/// cross-checked against Movesense's own `sbem2json` tool's JSON output —
/// see the format notes on each parsing step below. Movesense doesn't
/// publish an official spec for this binary layout; this is specifically
/// the encoding returned over the GSP FETCH_LOG command.
enum MovesenseSBEMDecoder {
    enum FieldType {
        case uint8, uint16, uint32, int64, float32

        var byteSize: Int {
            switch self {
            case .uint8: return 1
            case .uint16: return 2
            case .uint32: return 4
            case .int64: return 8
            case .float32: return 4
            }
        }
    }

    /// A leaf field: a JSON-dotted-path-like name and its wire type. Path
    /// values `"["`/`"]"` are array-boundary syntax markers, not real
    /// fields — they carry no type and are skipped during decoding.
    private struct Leaf {
        let path: String
        let type: FieldType?
    }

    private enum DescriptorEntry {
        case leaf(Leaf)
        case group(refs: [UInt8])
    }

    static func decode(_ data: Data, startDate: Date) throws -> RawSessionData {
        let bytes = [UInt8](data)
        guard bytes.count > 9, bytes[0..<8].elementsEqual(Array("SBEM0112".utf8)) else {
            throw SensorError.transferFailed("En-tête SBEM non reconnu.")
        }

        let (descriptors, dataStart) = try parseDescriptors(bytes)

        var accelX: [Double] = []
        var accelY: [Double] = []
        var accelZ: [Double] = []
        var accelTimestampsMs: [Double] = []
        var hrSamples: [HRSample] = []
        var hrIndex = 0

        var pos = dataStart
        while pos < bytes.count - 1 {
            let groupId = bytes[pos]
            let length = Int(bytes[pos + 1])
            let payloadStart = pos + 2
            let payloadEnd = payloadStart + length
            guard payloadEnd <= bytes.count else { break }
            defer { pos = payloadEnd }

            guard let fields = resolve(groupId, descriptors: descriptors) else { continue }

            var values: [String: [Double]] = [:]
            var offset = payloadStart
            var decodeOK = true
            for field in fields {
                guard let type = field.type else { continue } // "[" / "]" markers
                guard offset + type.byteSize <= payloadEnd else { decodeOK = false; break }
                let value = readValue(bytes, at: offset, type: type)
                values[field.path, default: []].append(value)
                offset += type.byteSize
            }
            guard decodeOK, offset == payloadEnd else { continue }

            if values.keys.contains(where: { $0.contains("MeasAcc") }) {
                let timestamp = values["Samples+Array.MeasAcc.Timestamp"]?.first
                let xs = values["Samples.Array.MeasAcc.ArrayAcc+x"] ?? []
                let ys = values["Samples.Array.MeasAcc.ArrayAcc.y"] ?? []
                let zs = values["Samples.Array.MeasAcc.ArrayAcc.z"] ?? []
                // Z carries the effort-correlated signal on this sensor's
                // mounting (observed 2026-08-06) and becomes the load signal.
                // Stored raw, not clamped at zero: GaitDetector derives the
                // gravity direction from the true acceleration vector, which
                // a rectified axis would distort. The load analysis clamps on
                // its own anyway (MechanicalCurveAnalyzer, ZoneTimeAccumulator).
                let n = min(xs.count, min(ys.count, zs.count))
                guard n > 0 else { continue }
                for i in 0..<n {
                    accelX.append(xs[i])
                    accelY.append(ys[i])
                    accelZ.append(zs[i])
                }
                // One timestamp per *chunk* (not per sample) — these span
                // real elapsed time, unlike interpolating within a chunk.
                if let timestamp { accelTimestampsMs.append(timestamp) }
            } else if values.keys.contains(where: { $0.contains("MeasHR") }) {
                if let average = values["Samples+Array.MeasHR.average"]?.first {
                    hrSamples.append(HRSample(timeOffset: TimeInterval(hrIndex), bpm: average))
                    hrIndex += 1
                }
            }
            // TimeDetailed entries carry wall-clock sync info we don't need
            // for analysis — skipped.
        }

        guard !accelZ.isEmpty else {
            throw SensorError.transferFailed("Aucun échantillon d'accélération décodé dans ce fichier SBEM.")
        }

        var sampleRateHz = 52.0
        if let first = accelTimestampsMs.first, let last = accelTimestampsMs.last, last > first {
            sampleRateHz = Double(accelZ.count) / ((last - first) / 1000)
        }

        return RawSessionData(
            startDate: startDate,
            accelSampleRateHz: sampleRateHz,
            axes: AccelerationAxes(x: accelX, y: accelY, z: accelZ),
            hrSamples: hrSamples
        )
    }

    // MARK: - Descriptor table

    /// Parses the leading text-ish descriptor table: a sequence of
    /// `[length][id][0x00][content]` entries, `content` being either
    /// `<PTH>path[\n<FRM>type]\x00` (a leaf field) or `<GRP>id,id,...\x00`
    /// (a composite referencing other descriptor ids, possibly other
    /// groups). Verified against a real file (2026-08-13): the declared
    /// `length` byte is `1 + content.count` — except for the very last
    /// entry before the data section, where it overshoots by one byte
    /// (bleeding into the first data chunk's own header); detected by the
    /// content's last byte not being the expected `0x00` and corrected by
    /// backing up one byte.
    private static func parseDescriptors(_ bytes: [UInt8]) throws -> (entries: [UInt8: DescriptorEntry], dataStart: Int) {
        var entries: [UInt8: DescriptorEntry] = [:]
        var pos = 9 // skip "SBEM0112" (8) + 1 leading version/padding byte
        while pos + 3 <= bytes.count {
            let length = Int(bytes[pos])
            let id = bytes[pos + 1]
            let pad = bytes[pos + 2]
            guard pad == 0, length >= 1 else { break }

            var contentLen = length - 1
            guard pos + 3 + contentLen <= bytes.count else { break }
            var content = Array(bytes[(pos + 3)..<(pos + 3 + contentLen)])
            if let last = content.last, last != 0 {
                content.removeLast()
                contentLen -= 1
            }

            if content.starts(with: Array("<PTH>".utf8)) {
                let rest = content.dropFirst(5)
                if let newlineIndex = rest.firstIndex(of: 0x0A) {
                    let path = String(decoding: rest[rest.startIndex..<newlineIndex], as: UTF8.self)
                    let afterNewline = rest[rest.index(after: newlineIndex)...]
                    let frmPrefix = Array("<FRM>".utf8)
                    if afterNewline.starts(with: frmPrefix) {
                        let typeBytes = afterNewline.dropFirst(5).filter { $0 != 0 }
                        let typeName = String(decoding: typeBytes, as: UTF8.self)
                        entries[id] = .leaf(Leaf(path: path, type: fieldType(named: typeName)))
                    } else {
                        entries[id] = .leaf(Leaf(path: path, type: nil))
                    }
                } else {
                    let path = String(decoding: rest.filter { $0 != 0 }, as: UTF8.self)
                    entries[id] = .leaf(Leaf(path: path, type: nil))
                }
            } else if content.starts(with: Array("<GRP>".utf8)) {
                let text = content.dropFirst(5).filter { $0 != 0 }
                let string = String(decoding: text, as: UTF8.self)
                let refs = string.split(separator: ",").compactMap { UInt8($0) }
                entries[id] = .group(refs: refs)
            } else {
                break
            }
            pos = pos + 3 + contentLen
        }
        return (entries, pos)
    }

    private static func fieldType(named name: String) -> FieldType? {
        switch name {
        case "uint8": return .uint8
        case "uint16": return .uint16
        case "uint32": return .uint32
        case "int64": return .int64
        case "float32": return .float32
        default: return nil
        }
    }

    /// Expands a descriptor id (leaf or group, possibly nested) into an
    /// ordered list of leaves, in the exact order fields are packed in a
    /// data chunk's payload.
    private static func resolve(_ id: UInt8, descriptors: [UInt8: DescriptorEntry], depth: Int = 0) -> [Leaf]? {
        guard depth < 16, let entry = descriptors[id] else { return nil }
        switch entry {
        case .leaf(let leaf):
            return [leaf]
        case .group(let refs):
            var result: [Leaf] = []
            for ref in refs {
                guard let expanded = resolve(ref, descriptors: descriptors, depth: depth + 1) else { return nil }
                result.append(contentsOf: expanded)
            }
            return result
        }
    }

    private static func readValue(_ bytes: [UInt8], at offset: Int, type: FieldType) -> Double {
        switch type {
        case .uint8:
            return Double(bytes[offset])
        case .uint16:
            return Double(UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        case .uint32:
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
            return Double(value)
        case .int64:
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
            return Double(Int64(bitPattern: value))
        case .float32:
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
            return Double(Float(bitPattern: value))
        }
    }
}
