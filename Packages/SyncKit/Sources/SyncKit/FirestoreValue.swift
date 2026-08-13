import Foundation

/// Firestore REST API's typed value wire format — every leaf value must be
/// wrapped by its type. See:
/// https://cloud.google.com/firestore/docs/reference/rest/v1/Value
public indirect enum FirestoreValue: Equatable {
    case string(String)
    case double(Double)
    case integer(Int)
    case boolean(Bool)
    case timestamp(Date)
    case null
    case map([String: FirestoreValue])

    /// Encodes to the raw `[String: Any]` shape Firestore's REST API expects,
    /// suitable for `JSONSerialization.data(withJSONObject:)`.
    public func encoded() -> [String: Any] {
        switch self {
        case .string(let value):
            return ["stringValue": value]
        case .double(let value):
            return ["doubleValue": value]
        case .integer(let value):
            // Firestore sends/expects int64 as a JSON *string*, not a number,
            // to avoid precision loss in JS number parsing.
            return ["integerValue": String(value)]
        case .boolean(let value):
            return ["booleanValue": value]
        case .timestamp(let value):
            return ["timestampValue": Self.iso8601.string(from: value)]
        case .null:
            return ["nullValue": NSNull()]
        case .map(let fields):
            return ["mapValue": ["fields": fields.mapValues { $0.encoded() }]]
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
