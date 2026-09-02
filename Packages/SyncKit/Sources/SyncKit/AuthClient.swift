import Foundation

/// Cached anonymous-auth credentials. `expiresAt` is derived from the auth
/// response's `expiresIn`/`expires_in` (~1h), refreshed on demand rather than
/// on a timer.
struct AuthTokenBundle: Codable {
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
    /// The account this token belongs to. Needed long before the team model
    /// lands: "this coach runs these teams" cannot mean anything without an
    /// identity to hang it on, and an anonymous account is a new person every
    /// time the app is reinstalled.
    var uid: String?
    /// Nil for an anonymous session, which is how the two are told apart.
    var email: String?
}

/// Who the app is signed in as, for the interface to show.
public struct AuthAccount: Sendable, Equatable {
    public let uid: String
    /// Nil means an anonymous session — a real account always has one.
    public let email: String?
    public var isAnonymous: Bool { email == nil }
}

/// Sign-in against Firebase Auth's REST surface — e-mail/password accounts,
/// plus the anonymous sign-in the app started with — with Keychain-backed
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

    /// Who is signed in, without a network call — nil when nothing is stored.
    public func currentAccount() -> AuthAccount? {
        let bundle = cached ?? loadFromKeychain()
        guard let bundle, let uid = bundle.uid else { return nil }
        return AuthAccount(uid: uid, email: bundle.email)
    }

    /// Creates a real account and adopts it.
    ///
    /// Deliberately replaces whatever was cached, anonymous or otherwise: two
    /// identities in one install is the confusion this exists to end.
    @discardableResult
    public func createAccount(email: String, password: String, webAPIKey: String) async throws -> AuthAccount {
        adopt(try await passwordCall(path: "accounts:signUp", email: email,
                                     password: password, webAPIKey: webAPIKey))
    }

    @discardableResult
    public func signIn(email: String, password: String, webAPIKey: String) async throws -> AuthAccount {
        adopt(try await passwordCall(path: "accounts:signInWithPassword", email: email,
                                     password: password, webAPIKey: webAPIKey))
    }

    /// Forgets the account on this device. The data on the server is untouched;
    /// signing back in reaches it again.
    public func signOut() {
        cached = nil
        KeychainStore.delete(account: keychainAccount)
    }

    private func adopt(_ bundle: AuthTokenBundle) -> AuthAccount {
        cached = bundle
        saveToKeychain(bundle)
        return AuthAccount(uid: bundle.uid ?? "", email: bundle.email)
    }

    private func currentBundle(webAPIKey: String) async throws -> AuthTokenBundle {
        // Prefer what is already in memory and only reach for the Keychain when
        // there is nothing — an expired in-memory bundle still carries the
        // refresh token and the identity, which is exactly what is needed next.
        if let stored = cached ?? loadFromKeychain() {
            if isValid(stored) {
                cached = stored
                return stored
            }
            if let refreshed = try? await refresh(refreshToken: stored.refreshToken, webAPIKey: webAPIKey) {
                cached = refreshed
                saveToKeychain(refreshed)
                return refreshed
            }
            // A real account whose refresh token no longer works (revoked,
            // password changed, account deleted) must NOT quietly become a new
            // anonymous account: that would look like the athlete's whole
            // history had vanished. Ask them to sign in again instead.
            if stored.email != nil {
                throw AuthError.notSignedIn
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
        let localId: String
    }

    private struct PasswordResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
        let localId: String
        let email: String?
    }

    /// `accounts:signUp` and `accounts:signInWithPassword` take the same body
    /// and answer in the same shape, so one function serves both.
    private func passwordCall(path: String, email: String, password: String,
                              webAPIKey: String) async throws -> AuthTokenBundle {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/\(path)?key=\(webAPIKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "returnSecureToken": true,
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AuthError.from(responseBody: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(PasswordResponse.self, from: data)
        return AuthTokenBundle(
            idToken: decoded.idToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn) ?? 3600),
            uid: decoded.localId,
            email: decoded.email ?? email
        )
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
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn) ?? 3600),
            uid: decoded.localId,
            email: nil
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
        // The refresh endpoint says nothing about the account, so the identity
        // is carried across from the bundle being refreshed. Dropping it here
        // would quietly turn a signed-in athlete anonymous an hour later.
        let previous = cached ?? loadFromKeychain()
        return AuthTokenBundle(
            idToken: decoded.id_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in) ?? 3600),
            uid: previous?.uid,
            email: previous?.email
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
