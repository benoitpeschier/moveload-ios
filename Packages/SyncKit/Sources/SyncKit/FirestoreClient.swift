import Foundation

/// Sends already-authenticated Firestore REST requests. One instance per
/// request is fine — it's a thin wrapper, the expensive part (auth) lives in
/// `AuthClient`.
public struct FirestoreClient: Sendable {
    private let projectID: String
    private let idToken: String
    private let session: URLSession

    public init(projectID: String, idToken: String, session: URLSession = .shared) {
        self.projectID = projectID
        self.idToken = idToken
        self.session = session
    }

    /// Full-overwrite upsert at a known document path built from
    /// `pathComponents` (each percent-encoded individually). Deliberately
    /// never sends `updateMask` — its absence makes Firestore replace the
    /// whole document with `fields`, which is what we want since every field
    /// is always sent on every call.
    public func upsertDocument(pathComponents: [String], fields: [String: FirestoreValue]) async throws {
        var request = URLRequest(url: documentURL(pathComponents: pathComponents))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["fields": fields.mapValues { $0.encoded() }]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try SyncError.validate(response, data: data)
    }

    /// Removes a document. A document that is already gone is treated as
    /// success: the caller's intent is "this must not be there", and Firestore
    /// answers 404 both for an already-deleted document and for one that never
    /// existed — neither is a failure worth surfacing.
    public func deleteDocument(pathComponents: [String]) async throws {
        var request = URLRequest(url: documentURL(pathComponents: pathComponents))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return }
        try SyncError.validate(response, data: data)
    }

    private func documentURL(pathComponents: [String]) -> URL {
        let encodedPath = pathComponents
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/\(encodedPath)")!
    }
}
