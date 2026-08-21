import Foundation

/// Device-local sync configuration — team code, Firebase project id, web API key.
/// Not athlete training data, so it's kept separate from PersistenceKit's SwiftData
/// schema and persisted via UserDefaults instead (see `SyncSettingsStore`).
public struct SyncSettings: Codable, Sendable, Equatable {
    public var teamCode: String
    public var projectID: String
    public var webAPIKey: String

    public init(teamCode: String = "", projectID: String = "", webAPIKey: String = "") {
        self.teamCode = teamCode
        self.projectID = projectID
        self.webAPIKey = webAPIKey
    }

    public var isConfigured: Bool {
        !teamCode.isEmpty && !projectID.isEmpty && !webAPIKey.isEmpty
    }

    // MARK: - Sharing

    /// The three settings as one string, for a QR code an already-configured
    /// device shows and a new one scans. Typing them by hand is the single
    /// worst moment of onboarding: the team code is deliberately long and
    /// random, the API key is forty opaque characters, and one wrong
    /// character fails silently as a sync that never lands.
    ///
    /// Shaped as a URL so a custom scheme or a universal link can be added
    /// later without invalidating codes already handed out. Nothing reads it
    /// as a URL today — it is scanned inside the app.
    public var shareablePayload: String {
        var components = URLComponents()
        components.scheme = Self.payloadScheme
        components.host = Self.payloadHost
        components.queryItems = [
            URLQueryItem(name: "c", value: teamCode),
            URLQueryItem(name: "p", value: projectID),
            URLQueryItem(name: "k", value: webAPIKey)
        ]
        return components.url?.absoluteString ?? ""
    }

    /// Reads a payload back, returning nil for anything that is not one —
    /// a QR code from another app, or one of ours missing a field. A partial
    /// configuration is worse than none: it looks set up and never syncs.
    public init?(shareablePayload: String) {
        guard let components = URLComponents(string: shareablePayload),
              components.scheme == Self.payloadScheme,
              components.host == Self.payloadHost,
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }

        self.init(teamCode: value("c"), projectID: value("p"), webAPIKey: value("k"))
        guard isConfigured else { return nil }
    }

    private static let payloadScheme = "moveload"
    private static let payloadHost = "team"
}

public struct AthleteSyncPayload: Sendable, Equatable {
    public let id: String
    public let name: String
    /// "H" or "F" — mirrors PersistenceKit's `Gender` without SyncKit depending on it.
    public let gender: String

    public init(id: String, name: String, gender: String) {
        self.id = id
        self.name = name
        self.gender = gender
    }
}

public struct SessionSyncPayload: Sendable, Equatable {
    public let id: String
    public let athleteId: String
    public let athleteName: String
    public let gender: String
    /// "K1" / "C1" / "KX" — mirrors PersistenceKit's `BoatType`.
    public let boatType: String
    public let date: Date
    public let durationSeconds: Double
    /// Athlete-given label, empty when the session goes by its date.
    public let name: String
    public let perceivedExertion: Int?
    /// Flags a session recorded under standardized test conditions — lets the
    /// coach webapp isolate comparable-effort sessions from regular training.
    public let isTest: Bool
    public let hrZone1Seconds: Double
    public let hrZone2Seconds: Double
    public let hrZone3Seconds: Double
    public let mechZone1Seconds: Double
    public let mechZone2Seconds: Double
    public let mechZone3Seconds: Double
    /// Peak value per rolling-window duration in seconds ("5"/"10"/"30"/"45"/"90"/"180");
    /// nil when the session was shorter than that window.
    public let mechanicalPeaks: [String: Double?]

    public init(
        id: String,
        athleteId: String,
        athleteName: String,
        gender: String,
        boatType: String,
        date: Date,
        durationSeconds: Double,
        name: String = "",
        perceivedExertion: Int?,
        isTest: Bool,
        hrZone1Seconds: Double,
        hrZone2Seconds: Double,
        hrZone3Seconds: Double,
        mechZone1Seconds: Double,
        mechZone2Seconds: Double,
        mechZone3Seconds: Double,
        mechanicalPeaks: [String: Double?]
    ) {
        self.id = id
        self.athleteId = athleteId
        self.athleteName = athleteName
        self.gender = gender
        self.boatType = boatType
        self.date = date
        self.durationSeconds = durationSeconds
        self.name = name
        self.perceivedExertion = perceivedExertion
        self.isTest = isTest
        self.hrZone1Seconds = hrZone1Seconds
        self.hrZone2Seconds = hrZone2Seconds
        self.hrZone3Seconds = hrZone3Seconds
        self.mechZone1Seconds = mechZone1Seconds
        self.mechZone2Seconds = mechZone2Seconds
        self.mechZone3Seconds = mechZone3Seconds
        self.mechanicalPeaks = mechanicalPeaks
    }
}
