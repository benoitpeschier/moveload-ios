import Foundation

public struct SBEMChunk: Sendable {
    public let id: UInt16
    public let payload: [UInt8]
}

/// Low-level reader for the Movesense SBEM binary log format.
///
/// Ground truth for this comes from `movesense-device-lib`'s public headers
/// (`Sbem.hpp`, `sbem_types.h`, `sbemdescriptor.hpp`), **plus direct
/// empirical validation against the official `sbem2json` CLI tool**
/// (downloaded from the movesense-device-lib Bitbucket downloads page):
/// hand-built byte sequences using the escape-based id/size scheme below
/// (including an escaped 300-byte payload) were fed to the real tool and
/// parsed with correct chunk boundaries every time (confirmed via its
/// `SmlStreamParser::parseChunk` log output correctly reporting each chunk
/// id with no truncation/misalignment errors) — so the **chunk framing
/// itself is now confirmed, not just inferred**:
///   - A leading id byte of `0xFF` escapes to a 2-byte little-endian id
///     (`Descriptor::id_t` is `uint16_t`); otherwise the byte is the literal
///     id (0–254). Same for a `0xFF` size byte escaping to a 4-byte
///     little-endian size (`writeSizeFull` takes a `uint32`).
///   - Chunk id `0` is reserved for descriptor chunks.
/// The version header is **not** a fixed string, though — probing the same
/// tool showed it writes `"SBEM0102"` for some outputs while accepting
/// `"SBEM0103"` as input, so only the 4-byte "SBEM" FOURCC is validated
/// here, not the trailing version digits.
public enum SBEMChunkReader {
    public static let versionHeaderSize = 8

    /// Validates the FOURCC and returns the remaining bytes. Throws
    /// `.compressedDataNotSupported` if the stream doesn't start with the
    /// "SBEM" FOURCC — per Movesense's own docs, logbook data may be
    /// Heatshrink-compressed, which isn't handled here yet.
    public static func stripHeaderAndValidate(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard bytes.count >= versionHeaderSize else { throw SBEMError.tooShortForHeader }
        let fourCC = String(decoding: bytes[0..<4], as: UTF8.self)
        guard fourCC == "SBEM" else { throw SBEMError.compressedDataNotSupported }
        return Array(bytes[versionHeaderSize...])
    }

    public static func readChunks(_ bytes: [UInt8]) throws -> [SBEMChunk] {
        var chunks: [SBEMChunk] = []
        var i = 0
        while i < bytes.count {
            let (id, afterId) = try readEscapedUInt16(bytes, i)
            let (size, afterSize) = try readEscapedUInt32(bytes, afterId)
            let end = afterSize + Int(size)
            guard end <= bytes.count else { throw SBEMError.truncatedChunk }
            chunks.append(SBEMChunk(id: id, payload: Array(bytes[afterSize..<end])))
            i = end
        }
        return chunks
    }

    private static func readEscapedUInt16(_ bytes: [UInt8], _ i: Int) throws -> (UInt16, Int) {
        guard i < bytes.count else { throw SBEMError.truncatedChunk }
        if bytes[i] == 0xFF {
            guard i + 3 <= bytes.count else { throw SBEMError.truncatedChunk }
            let value = UInt16(bytes[i + 1]) | (UInt16(bytes[i + 2]) << 8)
            return (value, i + 3)
        }
        return (UInt16(bytes[i]), i + 1)
    }

    private static func readEscapedUInt32(_ bytes: [UInt8], _ i: Int) throws -> (UInt32, Int) {
        guard i < bytes.count else { throw SBEMError.truncatedChunk }
        if bytes[i] == 0xFF {
            guard i + 5 <= bytes.count else { throw SBEMError.truncatedChunk }
            var value: UInt32 = 0
            for k in 0..<4 { value |= UInt32(bytes[i + 1 + k]) << (8 * k) }
            return (value, i + 5)
        }
        return (UInt32(bytes[i]), i + 1)
    }

    /// Inverse of `readEscapedUInt16`/`readEscapedUInt32` + chunk framing —
    /// used only by tests to build synthetic fixtures under the same
    /// assumed encoding as the reader above.
    static func writeChunk(id: UInt16, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: writeEscapedUInt16(id))
        bytes.append(contentsOf: writeEscapedUInt32(UInt32(payload.count)))
        bytes.append(contentsOf: payload)
        return bytes
    }

    private static func writeEscapedUInt16(_ value: UInt16) -> [UInt8] {
        if value >= 0xFF {
            return [0xFF, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
        return [UInt8(value)]
    }

    private static func writeEscapedUInt32(_ value: UInt32) -> [UInt8] {
        if value >= 0xFF {
            return [0xFF] + (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
        }
        return [UInt8(value)]
    }
}
