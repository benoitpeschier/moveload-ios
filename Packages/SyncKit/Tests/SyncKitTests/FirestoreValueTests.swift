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

/// Arrays reach Firestore as individually wrapped values — the REST API has no
/// packed numeric form. The stroke waveform is the first thing here to use one,
/// and getting the shape wrong would be rejected by the server rather than
/// caught locally.
final class FirestoreArrayEncodingTests: XCTestCase {

    func testAnArrayWrapsEveryElement() throws {
        let encoded = FirestoreValue.array([.double(1.5), .double(-0.25)]).encoded()
        let arrayValue = try XCTUnwrap(encoded["arrayValue"] as? [String: Any])
        let values = try XCTUnwrap(arrayValue["values"] as? [[String: Any]])

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["doubleValue"] as? Double, 1.5)
        XCTAssertEqual(values[1]["doubleValue"] as? Double, -0.25)
    }

    func testAnEmptyArrayStillCarriesAValuesKey() throws {
        let encoded = FirestoreValue.array([]).encoded()
        let arrayValue = try XCTUnwrap(encoded["arrayValue"] as? [String: Any])
        XCTAssertNotNil(arrayValue["values"] as? [[String: Any]])
    }

    /// It has to survive JSONSerialization, which is what actually goes on the
    /// wire — an encoding that only looks right in a dictionary is no use.
    func testItSerialisesAsJSON() throws {
        let payload = ["fields": ["signal": FirestoreValue.array([.double(0.5)]).encoded()]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("arrayValue"))
        XCTAssertTrue(text.contains("doubleValue"))
    }
}

/// Reading back from Firestore — the app's first read, and the one place where
/// a wrong assumption about the wire format would silently substitute the
/// coach's thresholds with nothing.
final class FirestoreFetchNumbersTests: XCTestCase {

    private func numbers(from json: String, status: Int = 200) async throws -> [String: Double]? {
        StubProtocol.status = status
        StubProtocol.body = Data(json.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = FirestoreClient(projectID: "p", idToken: "t", session: URLSession(configuration: config))
        return try await client.fetchNumbers(pathComponents: ["a", "b"])
    }

    func testDoublesAreRead() async throws {
        let result = try await numbers(from: #"{"fields":{"x":{"doubleValue":-48.5}}}"#)
        XCTAssertEqual(result?["x"], -48.5)
    }

    /// Firestore sends int64 as a JSON *string* to survive parsing, and a
    /// threshold typed as "-48" in the browser is stored as an integer — so
    /// reading only doubles would drop exactly the values a coach sets by hand.
    func testIntegersArriveAsStringsAndAreStillRead() async throws {
        let result = try await numbers(from: #"{"fields":{"x":{"integerValue":"-48"}}}"#)
        XCTAssertEqual(result?["x"], -48)
    }

    /// A coach who has set nothing is an ordinary answer, not a failure: the
    /// defaults stand.
    func testAMissingDocumentIsNilRatherThanAnError() async throws {
        let result = try await numbers(from: "{}", status: 404)
        XCTAssertNil(result)
    }

    func testADocumentWithNoFieldsIsEmptyNotNil() async throws {
        let result = try await numbers(from: #"{"name":"projects/p/documents/a/b"}"#)
        XCTAssertEqual(result, [:])
    }
}

/// Serves a canned response so the read can be tested without a project.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
