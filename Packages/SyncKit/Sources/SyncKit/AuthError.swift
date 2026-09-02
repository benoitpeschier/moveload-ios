import Foundation

/// Firebase Auth answers a failure with a machine-readable code inside a JSON
/// body. Handing that body to a sign-in form would show the athlete
/// `{"error":{"code":400,"message":"EMAIL_EXISTS"...`, so the codes worth
/// naming are named here and the rest fall back to the raw text.
public enum AuthError: Error, LocalizedError, Equatable {
    case emailAlreadyUsed
    case invalidEmail
    case weakPassword
    case wrongCredentials
    case accountDisabled
    case tooManyAttempts
    case passwordSignInDisabled
    case notSignedIn
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .emailAlreadyUsed:
            String(localized: "Cette adresse a déjà un compte. Utilisez « Se connecter ».", bundle: .module)
        case .invalidEmail:
            String(localized: "Cette adresse e-mail n'est pas valide.", bundle: .module)
        case .weakPassword:
            String(localized: "Le mot de passe doit faire au moins 6 caractères.", bundle: .module)
        case .wrongCredentials:
            String(localized: "Adresse e-mail ou mot de passe incorrect.", bundle: .module)
        case .accountDisabled:
            String(localized: "Ce compte a été désactivé.", bundle: .module)
        case .tooManyAttempts:
            String(localized: "Trop de tentatives. Réessayez dans quelques minutes.", bundle: .module)
        case .passwordSignInDisabled:
            String(localized: "La connexion par e-mail n'est pas activée sur le projet Firebase.", bundle: .module)
        case .notSignedIn:
            String(localized: "Aucun compte connecté sur cet appareil.", bundle: .module)
        case .other(let message):
            String(localized: "Échec de la connexion : \(message)", bundle: .module)
        }
    }

    /// Maps an identitytoolkit error body. The codes can carry a suffix after a
    /// space (`WEAK_PASSWORD : Password should be...`), hence the prefix match.
    static func from(responseBody body: String) -> AuthError {
        let code: String
        if let data = body.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            code = message
        } else {
            code = body
        }

        func has(_ needle: String) -> Bool { code.hasPrefix(needle) }
        switch true {
        case has("EMAIL_EXISTS"): return .emailAlreadyUsed
        case has("INVALID_EMAIL"), has("MISSING_EMAIL"): return .invalidEmail
        case has("WEAK_PASSWORD"), has("MISSING_PASSWORD"): return .weakPassword
        // Firebase merged the two "wrong e-mail" / "wrong password" codes into
        // one on purpose — telling them apart tells an attacker which addresses
        // are registered. Both older codes are still mapped for older projects.
        case has("INVALID_LOGIN_CREDENTIALS"), has("EMAIL_NOT_FOUND"),
             has("INVALID_PASSWORD"): return .wrongCredentials
        case has("USER_DISABLED"): return .accountDisabled
        case has("TOO_MANY_ATTEMPTS_TRY_LATER"): return .tooManyAttempts
        case has("OPERATION_NOT_ALLOWED"), has("PASSWORD_LOGIN_DISABLED"):
            return .passwordSignInDisabled
        default: return .other(code)
        }
    }
}
