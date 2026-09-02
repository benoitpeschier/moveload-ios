import XCTest
@testable import SyncKit

final class AuthErrorMappingTests: XCTestCase {
    private func mapped(_ message: String) -> AuthError {
        AuthError.from(responseBody: """
        {"error":{"code":400,"message":"\(message)","errors":[]}}
        """)
    }

    func testMapsTheCodesAFormCanActOn() {
        XCTAssertEqual(mapped("EMAIL_EXISTS"), .emailAlreadyUsed)
        XCTAssertEqual(mapped("INVALID_EMAIL"), .invalidEmail)
        XCTAssertEqual(mapped("USER_DISABLED"), .accountDisabled)
        XCTAssertEqual(mapped("TOO_MANY_ATTEMPTS_TRY_LATER"), .tooManyAttempts)
        // The one that will bite first if Email/Password is left off in the
        // Firebase console — it has to read as a setup problem, not a typo.
        XCTAssertEqual(mapped("OPERATION_NOT_ALLOWED"), .passwordSignInDisabled)
    }

    func testMapsCodesThatCarryATrailingExplanation() {
        XCTAssertEqual(
            mapped("WEAK_PASSWORD : Password should be at least 6 characters"),
            .weakPassword
        )
    }

    func testWrongEmailAndWrongPasswordAreIndistinguishable() {
        // Firebase deliberately merged these; keeping the older codes mapped to
        // the same case means the app never leaks which addresses are registered.
        XCTAssertEqual(mapped("INVALID_LOGIN_CREDENTIALS"), .wrongCredentials)
        XCTAssertEqual(mapped("EMAIL_NOT_FOUND"), .wrongCredentials)
        XCTAssertEqual(mapped("INVALID_PASSWORD"), .wrongCredentials)
    }

    func testUnknownCodeKeepsTheServerText() {
        XCTAssertEqual(mapped("SOMETHING_NEW"), .other("SOMETHING_NEW"))
    }

    func testNonJSONBodyDoesNotCrash() {
        XCTAssertEqual(AuthError.from(responseBody: "<html>502</html>"), .other("<html>502</html>"))
    }
}

final class AuthClientAccountTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        // These tests write through to the real Keychain; leaving an account
        // behind would make the next run start signed in.
        let client = AuthClient(session: session)
        Task { await client.signOut() }
        super.tearDown()
    }

    private func passwordResponse(uid: String, email: String, expiresIn: String = "3600") -> Data {
        Data("""
        {"idToken":"tok-\(uid)","refreshToken":"ref-\(uid)","expiresIn":"\(expiresIn)",
         "localId":"\(uid)","email":"\(email)"}
        """.utf8)
    }

    func testCreateAccountPostsCredentialsAndAdoptsTheIdentity() async throws {
        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=KEY"
            )
            let body = try XCTUnwrap(request.resolvedHTTPBody())
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["email"] as? String, "coach@club.fr")
            XCTAssertEqual(json["password"] as? String, "hunter22")
            XCTAssertEqual(json["returnSecureToken"] as? Bool, true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!,
                self.passwordResponse(uid: "u1", email: "coach@club.fr")
            )
        }

        let client = AuthClient(session: session)
        let account = try await client.createAccount(
            email: "coach@club.fr", password: "hunter22", webAPIKey: "KEY")

        XCTAssertEqual(account.uid, "u1")
        XCTAssertEqual(account.email, "coach@club.fr")
        XCTAssertFalse(account.isAnonymous)
        // Adopted, so no network call is needed to know who is signed in.
        let current = await client.currentAccount()
        XCTAssertEqual(current, account)
    }

    func testSignInUsesThePasswordEndpoint() async throws {
        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=KEY"
            )
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!,
                self.passwordResponse(uid: "u2", email: "athlete@club.fr")
            )
        }

        let client = AuthClient(session: session)
        let account = try await client.signIn(
            email: "athlete@club.fr", password: "hunter22", webAPIKey: "KEY")
        XCTAssertEqual(account.uid, "u2")
    }

    func testFailedSignInSurfacesTheMappedErrorNotTheRawBody() async {
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 400,
                                httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"code":400,"message":"INVALID_LOGIN_CREDENTIALS"}}"#.utf8)
            )
        }

        let client = AuthClient(session: session)
        do {
            _ = try await client.signIn(
                email: "athlete@club.fr", password: "wrong", webAPIKey: "KEY")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .wrongCredentials)
        }
    }

    func testExpiredRealAccountAsksToSignInRatherThanTurningAnonymous() async throws {
        // Sign in with a token that is already past the safety margin, so the
        // very next call must go through refresh.
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!,
                self.passwordResponse(uid: "u3", email: "athlete@club.fr", expiresIn: "0")
            )
        }
        let client = AuthClient(session: session)
        _ = try await client.signIn(
            email: "athlete@club.fr", password: "hunter22", webAPIKey: "KEY")

        // Refresh now fails — a revoked token, a deleted account, a changed
        // password. The old code answered this by silently creating a fresh
        // anonymous account, which reads to the athlete as "all my data is gone".
        var signUpWasCalled = false
        StubURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains("accounts:signUp") == true {
                signUpWasCalled = true
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 400,
                                httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"code":400,"message":"TOKEN_EXPIRED"}}"#.utf8)
            )
        }

        do {
            _ = try await client.validIDToken(webAPIKey: "KEY")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AuthError, .notSignedIn)
        }
        XCTAssertFalse(signUpWasCalled, "a signed-in athlete must never be silently made anonymous")
    }

    func testSignOutForgetsTheAccount() async throws {
        StubURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!,
                self.passwordResponse(uid: "u4", email: "coach@club.fr")
            )
        }
        let client = AuthClient(session: session)
        _ = try await client.signIn(
            email: "coach@club.fr", password: "hunter22", webAPIKey: "KEY")

        await client.signOut()
        let current = await client.currentAccount()
        XCTAssertNil(current)
    }
}
