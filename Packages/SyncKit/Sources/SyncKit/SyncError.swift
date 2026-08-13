import Foundation

public enum SyncError: Error, LocalizedError, Equatable {
    case notConfigured
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "La synchronisation n'est pas configurée (code d'équipe, projet ou clé API manquants)."
        case .requestFailed(let message):
            "Échec de la requête réseau : \(message)"
        }
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "réponse illisible"
            throw SyncError.requestFailed(body)
        }
    }
}
