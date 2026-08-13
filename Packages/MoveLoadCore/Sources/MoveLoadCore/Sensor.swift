import Foundation

public struct DiscoveredSensor: Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let rssi: Int?

    public init(id: String, name: String, rssi: Int?) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public enum SensorConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(DiscoveredSensor)
    case disconnecting
}

public struct LogbookEntryInfo: Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let startDate: Date
    public let duration: TimeInterval
    public let sizeBytes: Int?

    public init(id: String, startDate: Date, duration: TimeInterval, sizeBytes: Int?) {
        self.id = id
        self.startDate = startDate
        self.duration = duration
        self.sizeBytes = sizeBytes
    }
}

public struct LoggingConfig: Sendable, Codable {
    public let accelSampleRateHz: Double
    public let hrEnabled: Bool

    public init(accelSampleRateHz: Double = 52, hrEnabled: Bool = true) {
        self.accelSampleRateHz = accelSampleRateHz
        self.hrEnabled = hrEnabled
    }
}

public enum SensorError: Error, Sendable {
    case notConnected
    case scanTimedOut
    case connectionFailed(String)
    case transferFailed(String)
}

/// Without this, Swift's default `Error` → `NSError` bridging discards the
/// associated-value messages entirely and every failure surfaces to the user
/// as a generic "The operation couldn't be completed. (MoveLoadCore.SensorError
/// error N.)" — this restores the actual diagnostic text.
extension SensorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Capteur non connecté."
        case .scanTimedOut: return "Recherche du capteur expirée."
        case .connectionFailed(let reason): return "Connexion au capteur échouée : \(reason)"
        case .transferFailed(let reason): return "Échec de la communication avec le capteur : \(reason)"
        }
    }
}
