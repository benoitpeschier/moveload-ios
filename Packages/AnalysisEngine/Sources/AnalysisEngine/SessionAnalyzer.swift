import Foundation
import MoveLoadCore

public enum SessionAnalyzer {
    public static func analyze(session: RawSessionData, settings: AnalysisSettings) -> SessionAnalysisResult {
        let curveResult = MechanicalCurveAnalyzer.analyze(
            accelX: session.accelX,
            sampleRateHz: session.accelSampleRateHz
        )

        let thresholds = ZoneThresholds.mechanical(
            anchor: settings.confirmedMech45sAnchor,
            percentLow: settings.mechZonePercentLow,
            percentHigh: settings.mechZonePercentHigh
        )

        let mechZoneSeconds = ZoneTimeAccumulator.mechZoneSeconds(
            accelX: session.accelX,
            sampleRateHz: session.accelSampleRateHz,
            thresholdLow: thresholds.low,
            thresholdHigh: thresholds.high
        )

        let hrZoneSeconds = ZoneTimeAccumulator.hrZoneSeconds(
            hrSamples: session.hrSamples,
            sessionDuration: session.duration,
            thresholdLow: settings.hrThresholdLow,
            thresholdHigh: settings.hrThresholdHigh
        )

        return SessionAnalysisResult(
            hrZoneSeconds: hrZoneSeconds,
            mechZoneSeconds: mechZoneSeconds,
            curve: curveResult.curve,
            mechZoneAnchorUsed: settings.confirmedMech45sAnchor
        )
    }
}
