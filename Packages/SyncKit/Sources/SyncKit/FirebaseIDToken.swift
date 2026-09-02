import Foundation

/// Reads the caller's uid out of a Firebase ID token.
///
/// The uid is also cached alongside the token, but only for tokens minted
/// since that field existed: an install that signed in anonymously before then
/// has a perfectly valid token and no recorded uid, and re-signing in to learn
/// it would throw the account away. Reading the token is exact besides —
/// it yields the uid the *rules* will see, which is the one that matters.
///
/// No signature check: this is not authentication. The token was minted by
/// Firebase, kept in the Keychain, and is about to be handed straight back to
/// Google, which does verify it. Nothing here is trusted, only read.
enum FirebaseIDToken {
    static func uid(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url omits the padding that Data(base64Encoded:) requires.
        while payload.count % 4 != 0 { payload.append("=") }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Firebase sets both; `sub` is the standard claim and `user_id` the
        // one its own examples use, so neither is safe to assume alone.
        return (claims["user_id"] as? String) ?? (claims["sub"] as? String)
    }
}
