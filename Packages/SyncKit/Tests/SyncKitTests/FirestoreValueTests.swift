import XCTest
@testable import SyncKit

final class FirestoreValueTests: XCTestCase {
    func testStringValue() {
        let encoded = FirestoreValue.string("hello").encoded()
        XCTAssertEqual(encoded["stringValue"] as? String, "hello")
    }

    func testDoubleValue() {
        let encoded = FirestoreValue.double(1.5).encoded()
        XCTAssertEqual(encoded["doubleValue"] as? Double, 1.5)
    }

    func testIntegerValueIsEncodedAsString() {
        // Firestore expects int64 as a JSON string, not a number, to avoid
        // precision loss when the document is later read back in JS.
        let encoded = FirestoreValue.integer(5).encoded()
        XCTAssertEqual(encoded["integerValue"] as? String, "5")
    }

    func testNullValue() {
        let encoded = FirestoreValue.null.encoded()
        XCTAssertTrue(encoded["nullValue"] is NSNull)
    }

    func testTimestampValueRoundTrips() throws {
        let date = Date()
        let encoded = FirestoreValue.timestamp(date).encoded()
        let string = try XCTUnwrap(encoded["timestampValue"] as? String)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try XCTUnwrap(formatter.date(from: string))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.01)
    }

    func testMapValueNestsFieldsRecursively() throws {
        let encoded = FirestoreValue.map(["a": .string("x"), "b": .null]).encoded()
        let mapValue = try XCTUnwrap(encoded["mapValue"] as? [String: Any])
        let fields = try XCTUnwrap(mapValue["fields"] as? [String: Any])

        let aValue = try XCTUnwrap(fields["a"] as? [String: Any])
        XCTAssertEqual(aValue["stringValue"] as? String, "x")

        let bValue = try XCTUnwrap(fields["b"] as? [String: Any])
        XCTAssertTrue(bValue["nullValue"] is NSNull)
    }

    /// The exact shape used for a session's 6-window peak map — nil peaks
    /// (session shorter than the window) must come through as nullValue, not
    /// be silently dropped.
    func testMechanicalPeaksMapWithNilEntries() throws {
        let peaks: [String: Double?] = ["5": 3.2, "180": nil]
        let fields = peaks.mapValues { $0.map(FirestoreValue.double) ?? .null }
        let encoded = FirestoreValue.map(fields).encoded()
        let mapValue = try XCTUnwrap(encoded["mapValue"] as? [String: Any])
        let innerFields = try XCTUnwrap(mapValue["fields"] as? [String: Any])

        let fiveSeconds = try XCTUnwrap(innerFields["5"] as? [String: Any])
        XCTAssertEqual(fiveSeconds["doubleValue"] as? Double, 3.2)

        let threeMin = try XCTUnwrap(innerFields["180"] as? [String: Any])
        XCTAssertTrue(threeMin["nullValue"] is NSNull)
    }
}
