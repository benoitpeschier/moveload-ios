import Foundation

public enum MechanicalWindow: CaseIterable, Sendable, Codable, Hashable {
    case s3, s6, s9, s15, s30, s45, s90, s180

    public var seconds: Double {
        switch self {
        case .s3: 3
        case .s6: 6
        case .s9: 9
        case .s15: 15
        case .s30: 30
        case .s45: 45
        case .s90: 90
        case .s180: 180
        }
    }

    public var label: String {
        switch self {
        case .s3: "3 s"
        case .s6: "6 s"
        case .s9: "9 s"
        case .s15: "15 s"
        case .s30: "30 s"
        case .s45: "45 s"
        case .s90: "90 s"
        case .s180: "3 min"
        }
    }

    public static let anchorWindow: MechanicalWindow = .s45
}
