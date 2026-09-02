import Foundation
import MoveLoadCore

public enum SessionAnalyzer {

    /// Everything the zone figures are read from, before any threshold is
    /// applied: the effort signal with gravity removed, and the mask saying
    /// which samples count.
    ///
    /// Extracted so experiments — a different averaging window, a different
    /// pair of percentages — run on exactly the input the app uses. The last
    /// time this was reimplemented outside the analyser, the reimplementation
    /// diluted excluded stretches into the rolling mean and disagreed with the
    /// app by minutes; the app was right.
    struct Prepared {
        let signal: [Double]
        let keepMask: [Bool]
        let curveMask: [Bool]?
        let excludedWalkingSeconds: TimeInterval
        let inactiveSeconds: TimeInterval
    }

    static func prepared(session: RawSessionData, isConditioning: Bool = false) -> Prepared {
        // A conditioning session — running, gym, circuits — is walking and
        // running and standing still by design. The two detectors exist to
        // strip those from a paddling session, so here they would throw away
        // the session itself. Everything counts, and the whole recording is
        // read as one span.
        if isConditioning {
            let effort = EffortSignal.dynamic(session.accelX, sampleRateHz: session.accelSampleRateHz)
            return Prepared(
                signal: effort,
                keepMask: [Bool](repeating: true, count: session.accelX.count),
                curveMask: nil,
                excludedWalkingSeconds: 0,
                inactiveSeconds: 0
            )
        }

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

        return Prepared(
            signal: effort,
            keepMask: countedMask,
            curveMask: keepMask,
            excludedWalkingSeconds: excludedSeconds,
            inactiveSeconds: inactivity.inactiveSeconds
        )
    }

    public static func analyze(
        session: RawSessionData,
        settings: AnalysisSettings,
        isConditioning: Bool = false
    ) -> SessionAnalysisResult {
        let prepared = prepared(session: session, isConditioning: isConditioning)
        let effort = prepared.signal
        let countedMask = prepared.keepMask

        // Chest acceleration during a run is stride, not paddling: it would
        // produce peaks far above anything on the water and, left in, would
        // become the athlete's 45 s reference and rewrite every zone. So the
        // mechanical side is not merely hidden for these sessions, it is not
        // produced — no curve means nothing for the record queries to find.
        guard !isConditioning else {
            return SessionAnalysisResult(
                hrZoneSeconds: ZoneTimeAccumulator.hrZoneSeconds(
                    hrSamples: session.hrSamples,
                    sessionDuration: session.duration,
                    thresholdLow: settings.hrThresholdLow,
                    thresholdHigh: settings.hrThresholdHigh,
                    keptRanges: nil
                ),
                mechZoneSeconds: [:],
                curve: [:],
                mechZoneAnchorUsed: 0,
                excludedWalkingSeconds: 0,
                inactiveSeconds: 0,
                secondsAboveAnchor: 0
            )
        }

        let curveResult = prepared.curveMask.map {
            MechanicalCurveAnalyzer.analyze(
                accelX: effort,
                sampleRateHz: session.accelSampleRateHz,
                keepMask: $0
            )
        } ?? MechanicalCurveAnalyzer.analyze(
            accelX: effort,
            sampleRateHz: session.accelSampleRateHz
        )

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

        // The best nine seconds, sample for sample. The curve analyser already
        // knows where that window sits — it tracked the position while finding
        // the peak — and the slice is taken from the same effort signal the
        // peak was measured on, so the picture and the number cannot disagree.
        var bestNine: [Double] = []
        if let startSeconds = curveResult.peakStartSeconds[.s9] ?? nil {
            let rate = session.accelSampleRateHz
            let first = Int((startSeconds * rate).rounded())
            let length = Int((MechanicalWindow.s9.seconds * rate).rounded())
            if first >= 0, first + length <= effort.count {
                bestNine = Array(effort[first..<(first + length)])
            }
        }

        return SessionAnalysisResult(
            hrZoneSeconds: hrZoneSeconds,
            mechZoneSeconds: mechZoneSeconds,
            curve: curveResult.curve,
            mechZoneAnchorUsed: settings.confirmedMech45sAnchor,
            excludedWalkingSeconds: prepared.excludedWalkingSeconds,
            inactiveSeconds: prepared.inactiveSeconds,
            bestNineSecondsSignal: bestNine,
            bestNineSecondsRateHz: bestNine.isEmpty ? 0 : session.accelSampleRateHz,
            secondsAboveAnchor: secondsAboveAnchor
        )
    }
}
