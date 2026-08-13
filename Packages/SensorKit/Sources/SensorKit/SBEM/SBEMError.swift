import Foundation

public enum SBEMError: Error, Sendable, Equatable {
    case tooShortForHeader
    case unrecognizedHeader(String)
    /// Movesense logbook data can be Heatshrink-compressed; only the
    /// uncompressed "SBEM" FOURCC form is handled so far.
    case compressedDataNotSupported
    case truncatedChunk
}
