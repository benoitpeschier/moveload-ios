import XCTest
@testable import SyncKit

final class FirestoreClientTests: XCTestCase {
    func testUpsertDocumentSendsExpectedPATCHRequest() async throws {
        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://firestore.googleapis.com/v1/projects/proj1/databases/(default)/documents/teams/team%20code/athletes/ath1"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
            // No updateMask — its absence is what makes this a full-document overwrite.
            XCTAssertNil(request.url?.query)

            let bodyData = try XCTUnwrap(request.resolvedHTTPBody())
            let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let fields = try XCTUnwrap(json?["fields"] as? [String: Any])
            let nameValue = try XCTUnwrap(fields["name"] as? [String: Any])
            XCTAssertEqual(nameValue["stringValue"] as? String, "Jane")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        defer { StubURLProtocol.requestHandler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = FirestoreClient(projectID: "proj1", idToken: "tok123", session: session)
        try await client.upsertDocument(
            pathComponents: ["teams", "team code", "athletes", "ath1"],
            fields: ["name": .string("Jane")]
        )
    }

    func testUpsertDocumentThrowsOnNonSuccessStatus() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data("permission denied".utf8))
        }
        defer { StubURLProtocol.requestHandler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = FirestoreClient(projectID: "proj1", idToken: "tok123", session: session)
        do {
            try await client.upsertDocument(pathComponents: ["teams", "t"], fields: [:])
            XCTFail("expected upsertDocument to throw on a 403 response")
        } catch let SyncError.requestFailed(message) {
            XCTAssertTrue(message.contains("permission denied"))
        } catch {
            XCTFail("expected SyncError.requestFailed, got \(error)")
        }
    }
}
