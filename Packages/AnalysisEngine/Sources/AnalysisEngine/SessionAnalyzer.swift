import Foundation
import MoveLoadCore

public enum SessionAnalyzer {
    public static func analyze(session: RawSessionData, settings: AnalysisSettings) -> SessionAnalysisResult {
        // Walking to and from the water otherwise dominates the peak curve —
        // see GaitDetector. Skipped for sources without triaxial data, which
        // can't be judged and are analysed whole, as before.
        var keepMask: [Bool]?
        var excludedSeconds: TimeInterval = 0
        if let axes = session.axes, axes.count == session.accelX.count {
            let gait = GaitDetector.detect(axes: axes, sampleRateHz: session.accelSampleRateHz)
            // Refuse to act on an implausible verdict: if almost nothing
            // survives, the detector is more likely wrong than the session
            // is, and silently reporting a near-empty session would be worse
            // than including some walking.
            let keptFraction = Double(gait.keepMask.filter { $0 }.count) / Double(max(gait.keepMask.count, 1))
            if keptFraction >= 0.1 {
                keepMask = gait.keepMask
                excludedSeconds = gait.excludedSeconds
            }
        }

        let curveResult = keepMask.map {
            MechanicalCurveAnalyzer.analyze(
                accelX: session.accelX,
                sampleRateHz: session.accelSampleRateHz,
                keepMask: $0
            )
        } ?? MechanicalCurveAnalyzer.analyze(
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
            thresholdHigh: thresholds.high,
            keepMask: keepMask
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
            mechZoneAnchorUsed: settings.confirmedMech45sAnchor,
            excludedWalkingSeconds: excludedSeconds
        )
    }
}
