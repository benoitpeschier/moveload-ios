import SwiftUI
import AnalysisEngine

/// The colour each fatigue pattern is shown in.
///
/// In one place because the same morning is named on two screens — the HRV
/// history and the day view — and a pattern that changes colour between them
/// reads as a different pattern.
extension FatiguePatterns.Pattern {
    var colour: Color {
        switch self {
        case .energyCollapse:       Color(red: 0.75, green: 0.22, blue: 0.17)
        case .acuteStress:          Color(red: 0.85, green: 0.49, blue: 0.05)
        case .activationBrake:      Color(red: 0.48, green: 0.32, blue: 0.19)
        case .extremeFatigue:       Color.primary
        case .peripheralRegulation: Color(red: 0.48, green: 0.31, blue: 0.66)
        }
    }
}

/// A morning with no pattern at all is a result, not an absence — it needs a
/// name and a colour of its own, or the screen looks like it failed.
enum FatigueBalance {
    static let colour = Color.green
    static var name: String { String(localized: "Équilibre physiologique") }
}
