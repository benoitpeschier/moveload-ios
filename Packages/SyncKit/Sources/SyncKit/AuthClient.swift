import Foundation

/// Cached anonymous-auth credentials. `expiresAt` is derived from the auth
/// response's `expiresIn`/`expires_in` (~1h), refreshed on demand rather than
/// on a timer.
struct AuthTokenBundle: Codable {
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// Anonymous sign-in against Firebase Auth's REST surface, with Keychain-backed
/// token caching and refresh-on-demand. Deliberately hand-rolled instead of the
/// firebase-ios-sdk (see plan notes: that SDK is heavy to resolve/build via SPM
/// and this project avoids vendoring big dependencies where a small REST client
/// suffices — same reasoning as the hand-rolled SBEM decoder in SensorKit).
public actor AuthClient {
    private let keychainAccount = "firebaseAuthTokens"
    private let session: URLSession
    private var cached: AuthTokenBundle?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A valid (non-expired, 5-minute safety margin) idToken, refreshing or
    /// re-signing-in as needed.
    public func validIDToken(webAPIKey: String) async throws -> String {
        try await currentBundle(webAPIKey: webAPIKey).idToken
    }

    private func currentBundle(webAPIKey: String) async throws -> AuthTokenBundle {
        if let cached, isValid(cached) {
            return cached
        }
        if let stored = loadFromKeychain() {
            if isValid(stored) {
                cached = stored
                return stored
            }
            if let refreshed = try? await refresh(refreshToken: stored.refreshToken, webAPIKey: webAPIKey) {
                cached = refreshed
                saveToKeychain(refreshed)
                return refreshed
            }
        }
        let signedUp = try await signUp(webAPIKey: webAPIKey)
        cached = signedUp
        saveToKeychain(signedUp)
        return signedUp
    }

    private func isValid(_ bundle: AuthTokenBundle) -> Bool {
        bundle.expiresAt > Date().addingTimeInterval(300)
    }

    // MARK: - Firebase Auth REST calls

    private struct SignUpResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
    }

    private func signUp(webAPIKey: String) async throws -> AuthTokenBundle {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(webAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["returnSecureToken": true])

        let (data, response) = try await session.data(for: request)
        try SyncError.validate(response, data: data)
        let decoded = try JSONDecoder().decode(SignUpResponse.self, from: data)
        return AuthTokenBundle(
            idToken: decoded.idToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn) ?? 3600)
        )
    }

    /// Note the response here is snake_case (`id_token`, `refresh_token`,
    /// `expires_in`), unlike `accounts:signUp`'s camelCase — a genuine
    /// inconsistency in Firebase's REST surface, not a typo.
    private struct RefreshResponse: Decodable {
        let id_token: String
        let refresh_token: String
        let expires_in: String
    }

    private func refresh(refreshToken: String, webAPIKey: String) async throws -> AuthTokenBundle {
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(webAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(encodedToken)".utf8)

        let (data, response) = try await session.data(for: request)
        try SyncError.validate(response, data: data)
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return AuthTokenBundle(
            idToken: decoded.id_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in) ?? 3600)
        )
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> AuthTokenBundle? {
        guard let data = KeychainStore.load(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(AuthTokenBundle.self, from: data)
    }

    private func saveToKeychain(_ bundle: AuthTokenBundle) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        KeychainStore.save(data, account: keychainAccount)
    }
}
