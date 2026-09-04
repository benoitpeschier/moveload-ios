import Foundation

public enum SyncError: Error, LocalizedError, Equatable {
    case notConfigured
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "La synchronisation n'est pas configurée (code d'équipe, projet ou clé API manquants).", bundle: .module)
        case .requestFailed(let message):
            String(localized: "Échec de la requête réseau : \(message)", bundle: .module)
        }
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
                ?? String(localized: "réponse illisible", bundle: .module)
            throw SyncError.requestFailed(body)
        }
    }
}
