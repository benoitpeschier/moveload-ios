import Foundation

/// Maps SBEM descriptor value-ids to the whiteboard resource path they
/// describe, built from the `/Mem/Logbook/byId/{Id}/Descriptors` stream.
///
/// Chunk id `0` is the reserved "this chunk defines a descriptor" marker.
/// Its payload structure was reverse-engineered by disassembling the
/// official `sbem2json` tool's `BSML::SmlDescriptor::parseDescriptor`
/// (downloaded from the movesense-device-lib Bitbucket downloads page,
/// x86_64 binary, run under Rosetta) — **confirmed structurally**, not
/// just inferred from headers:
///   - The first **2 bytes** are the descriptor's own id, little-endian
///     (matches `Descriptor::id_t` being `uint16_t`).
///   - The rest is one or more `\n`-separated lines, each shaped
///     `<TAG>content`, where `content` runs to the end of the line.
///     `TAG` is looked up in a small fixed table and dispatches to a
///     specific parser — the ones identified so far (via C++ symbol names
///     `SmlDescriptor::parsePath/parseFormat/parseModifier/parseGroup/
///     parseReference/parseQuery`) are `PTH` (path), `FRM` (format), `MOD`
///     (modifier), `GRP` (group), `REF` (reference), `QRY` (query).
///
/// **Still unresolved** despite active probing against the real tool: the
/// exact rules for when a descriptor is considered *complete* (e.g.
/// whether a lone `PTH`+`FRM` pair is valid on its own or must be
/// referenced by a `GRP` descriptor), and the precise `FRM`/`MOD` value
/// grammar. Every hand-built test descriptor tried so far was rejected by
/// the real tool for reasons beyond just chunk framing, so treat the `PTH`
/// line extraction below as reverse-engineered-but-unconfirmed-end-to-end.
public struct SBEMDescriptorTable: Sendable {
    public struct DescriptorInfo: Sendable {
        public let id: UInt16
        public let path: String?
        public let rawLines: [String]
    }

    public let descriptors: [DescriptorInfo]

    public init(chunks: [SBEMChunk]) {
        var result: [DescriptorInfo] = []
        for chunk in chunks where chunk.id == 0 {
            guard chunk.payload.count >= 2 else { continue }
            let id = UInt16(chunk.payload[0]) | (UInt16(chunk.payload[1]) << 8)
            let text = String(decoding: chunk.payload[2...], as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

            var path: String?
            for line in lines where line.hasPrefix("<PTH>") {
                path = String(line.dropFirst(5))
            }
            result.append(DescriptorInfo(id: id, path: path, rawLines: lines))
        }
        self.descriptors = result
    }

    /// Raw tag lines per descriptor, joined — always safe to inspect
    /// regardless of whether `PTH` extraction above is fully correct.
    public var rawDescriptorStrings: [String] {
        descriptors.map { $0.rawLines.joined(separator: "\n") }
    }

    /// First descriptor id whose extracted `PTH` contains `needle`
    /// (case-insensitive).
    public func firstId(pathContains needle: String) -> UInt16? {
        descriptors.first { ($0.path ?? "").localizedCaseInsensitiveContains(needle) }?.id
    }
}
