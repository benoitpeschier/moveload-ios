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
    public let isConditioning: Bool
    /// Only carried for test sessions — see SyncService.
    public let bestNineSecondsSignal: [Double]
    public let bestNineSecondsRateHz: Double
    public let hrZone1Seconds: Double
    public let hrZone2Seconds: Double
    public let hrZone3Seconds: Double
    public let mechZone1Seconds: Double
    public let mechZone2Seconds: Double
    public let mechZone3Seconds: Double
    /// Seconds above the athlete's confirmed 45 s reference, from the
    /// instantaneous signal — the hard-work figure the zones cannot express.
    public let secondsAboveAnchor: Double
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
        isConditioning: Bool,
        bestNineSecondsSignal: [Double] = [],
        bestNineSecondsRateHz: Double = 0,
        hrZone1Seconds: Double,
        hrZone2Seconds: Double,
        hrZone3Seconds: Double,
        mechZone1Seconds: Double,
        mechZone2Seconds: Double,
        mechZone3Seconds: Double,
        secondsAboveAnchor: Double = 0,
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
        self.isConditioning = isConditioning
        self.bestNineSecondsSignal = bestNineSecondsSignal
        self.bestNineSecondsRateHz = bestNineSecondsRateHz
        self.hrZone1Seconds = hrZone1Seconds
        self.hrZone2Seconds = hrZone2Seconds
        self.hrZone3Seconds = hrZone3Seconds
        self.mechZone1Seconds = mechZone1Seconds
        self.mechZone2Seconds = mechZone2Seconds
        self.mechZone3Seconds = mechZone3Seconds
        self.secondsAboveAnchor = secondsAboveAnchor
        self.mechanicalPeaks = mechanicalPeaks
    }
}


/// One morning test, as the coach sees it.
///
/// **The five Wellness answers are deliberately absent.** Only the score
/// travels: an athlete who knows their "stress 2/5" is read by their coach
/// stops answering honestly, and the questionnaire is worth having only as an
/// honest contradiction of the measurement. There is no field here to put them
/// in, which is stronger than remembering not to fill one.
public struct HRVTestSyncPayload: Codable, Sendable {
    public let id: String
    public let athleteId: String
    public let date: Date

    public let supineMeanHR: Double
    public let supineRMSSD: Double
    public let supineTotalPower: Double
    public let supineLFOverHF: Double
    /// Kept because the fatigue-pattern rules are expressed on LF and HF
    /// individually, not on their ratio — the ratio cannot be taken apart.
    public let supineLF: Double
    public let supineHF: Double

    public let standingMeanHR: Double
    public let standingRMSSD: Double
    public let standingTotalPower: Double
    public let standingLFOverHF: Double
    public let standingLF: Double
    public let standingHF: Double

    public let wellnessScore: Int?
    /// Flagged so the coach is not shown a spectrum the engine itself distrusts.
    public let isReliable: Bool

    public init(
        id: String, athleteId: String, date: Date,
        supineMeanHR: Double, supineRMSSD: Double, supineTotalPower: Double, supineLFOverHF: Double,
        supineLF: Double, supineHF: Double,
        standingMeanHR: Double, standingRMSSD: Double, standingTotalPower: Double, standingLFOverHF: Double,
        standingLF: Double, standingHF: Double,
        wellnessScore: Int?, isReliable: Bool
    ) {
        self.id = id
        self.athleteId = athleteId
        self.date = date
        self.supineMeanHR = supineMeanHR
        self.supineRMSSD = supineRMSSD
        self.supineTotalPower = supineTotalPower
        self.supineLFOverHF = supineLFOverHF
        self.supineLF = supineLF
        self.supineHF = supineHF
        self.standingMeanHR = standingMeanHR
        self.standingRMSSD = standingRMSSD
        self.standingTotalPower = standingTotalPower
        self.standingLFOverHF = standingLFOverHF
        self.standingLF = standingLF
        self.standingHF = standingHF
        self.wellnessScore = wellnessScore
        self.isReliable = isReliable
    }
}
