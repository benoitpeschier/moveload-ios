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
        let encodedPath = pathComponents
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/\(encodedPath)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["fields": fields.mapValues { $0.encoded() }]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try SyncError.validate(response, data: data)
    }
}
