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

    /// Reads a document's numeric fields, or nil when it does not exist.
    ///
    /// The app's first *read* from Firestore — until now it only ever wrote.
    /// A missing document is an ordinary answer here, not an error: the coach
    /// simply has not set anything for this athlete, and the defaults stand.
    public func fetchNumbers(pathComponents: [String]) async throws -> [String: Double]? {
        var request = URLRequest(url: documentURL(pathComponents: pathComponents))
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try SyncError.validate(response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String: Any]
        else { return [:] }

        var numbers: [String: Double] = [:]
        for (key, wrapped) in fields {
            guard let value = wrapped as? [String: Any] else { continue }
            // Firestore hands back whichever numeric wrapper it stored, and
            // int64 arrives as a *string* to survive JSON. Both are read: a
            // threshold typed as "-48" in the browser comes back as an integer.
            if let d = value["doubleValue"] as? Double { numbers[key] = d }
            else if let i = value["integerValue"] as? String, let d = Double(i) { numbers[key] = d }
            else if let i = value["integerValue"] as? Int { numbers[key] = Double(i) }
        }
        return numbers
    }

    /// One array-of-strings field, or an empty array when the document, the
    /// field or the array is absent. Used for `teamIds`, which has to be read
    /// before it is written: a phone knows the one team it is configured for,
    /// and overwriting the list with that single value would drop an athlete
    /// out of every other team they belong to.
    public func fetchStringArray(pathComponents: [String], field: String) async throws -> [String] {
        var request = URLRequest(url: documentURL(pathComponents: pathComponents))
        request.httpMethod = "GET"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return [] }
        try SyncError.validate(response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = root["fields"] as? [String: Any],
              let wrapped = fields[field] as? [String: Any],
              let arrayValue = wrapped["arrayValue"] as? [String: Any],
              let values = arrayValue["values"] as? [[String: Any]]
        else { return [] }

        return values.compactMap { $0["stringValue"] as? String }
    }

    private func documentURL(pathComponents: [String]) -> URL {
        let encodedPath = pathComponents
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/\(encodedPath)")!
    }
}
