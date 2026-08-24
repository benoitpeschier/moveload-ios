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

        // Load is computed from the *dynamic* part of the axis: the raw signal
        // includes gravity, which made a motionless sensor outscore real
        // paddling. See EffortSignal. Gait detection above deliberately keeps
        // the raw axes, since it locates gravity on purpose.
        let effort = EffortSignal.dynamic(session.accelX, sampleRateHz: session.accelSampleRateHz)

        let curveResult = keepMask.map {
            MechanicalCurveAnalyzer.analyze(
                accelX: effort,
                sampleRateHz: session.accelSampleRateHz,
                keepMask: $0
            )
        } ?? MechanicalCurveAnalyzer.analyze(
            accelX: effort,
            sampleRateHz: session.accelSampleRateHz
        )

        // Zone time drops the stretches with no effort at all — riding a
        // conveyor, resting, waiting between runs — which otherwise pile into
        // zone 1 and describe the session as easier and longer than it was.
        // Deliberately not applied to the peak curve above: motionless time
        // never wins a peak, and cutting the recording further would fragment
        // it enough to make the long windows unmeasurable.
        let inactivity = InactivityDetector.detect(
            effort: effort,
            sampleRateHz: session.accelSampleRateHz,
            excluded: keepMask
        )
        let countedMask: [Bool] = (0..<session.accelX.count).map { i in
            let kept = keepMask.map { $0[i] } ?? true
            return kept && inactivity.activeMask[i]
        }

        let thresholds = ZoneThresholds.mechanical(
            anchor: settings.confirmedMech45sAnchor,
            percentLow: settings.mechZonePercentLow,
            percentHigh: settings.mechZonePercentHigh
        )

        let secondsAboveAnchor = ZoneTimeAccumulator.secondsAboveAnchor(
            accelX: effort,
            sampleRateHz: session.accelSampleRateHz,
            anchor: settings.confirmedMech45sAnchor,
            keepMask: countedMask
        )
        let mechZoneSeconds = ZoneTimeAccumulator.mechZoneSeconds(
            accelX: effort,
            sampleRateHz: session.accelSampleRateHz,
            thresholdLow: thresholds.low,
            thresholdHigh: thresholds.high,
            keepMask: countedMask
        )

        // Cardio is restricted to the same stretches as the mechanical load, so
        // both charts describe the same span of the session — walking to the
        // water otherwise showed up in one and not the other.
        let hrZoneSeconds = ZoneTimeAccumulator.hrZoneSeconds(
            hrSamples: session.hrSamples,
            sessionDuration: session.duration,
            thresholdLow: settings.hrThresholdLow,
            thresholdHigh: settings.hrThresholdHigh,
            keptRanges: GaitDetector.keptTimeRanges(
                keepMask: countedMask,
                sampleRateHz: session.accelSampleRateHz
            )
        )

        return SessionAnalysisResult(
            hrZoneSeconds: hrZoneSeconds,
            mechZoneSeconds: mechZoneSeconds,
            curve: curveResult.curve,
            mechZoneAnchorUsed: settings.confirmedMech45sAnchor,
            excludedWalkingSeconds: excludedSeconds,
            inactiveSeconds: inactivity.inactiveSeconds,
            secondsAboveAnchor: secondsAboveAnchor
        )
    }
}
