import Foundation

/// Human-readable chunk listing for manually sanity-checking a real
/// captured `.sbem` file (e.g. fetched via `wbcmd`) against what this
/// reader thinks the framing is. Not used by the app itself.
public enum SBEMDebugDump {
    public static func describe(_ data: Data) -> String {
        do {
            let bytes = try SBEMChunkReader.stripHeaderAndValidate(data)
            let chunks = try SBEMChunkReader.readChunks(bytes)
            var lines = ["\(chunks.count) chunk(s):"]
            for chunk in chunks {
                let preview = chunk.payload.prefix(16)
                let hex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
                let suffix = chunk.payload.count > 16 ? " ..." : ""
                lines.append("  id=\(chunk.id) len=\(chunk.payload.count) bytes=[\(hex)\(suffix)]")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Failed to parse: \(error)"
        }
    }
}
