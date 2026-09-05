import Foundation
import AnalysisEngine
import PersistenceKit

/// Turns a morning's test plus the athlete's history into a fatigue reading.
///
/// Kept apart from the view because choosing the reference is a judgement with
/// consequences — the same morning reads differently against yesterday, against
/// three days ago, or against the median of six — and that judgement deserves
/// to be readable and testable on its own.
enum HRVVerdict {

    enum Reference: Int, CaseIterable {
        case previous = 0        // N-1
        case threeBack = 1       // N-3
        case sixBack = 2         // N-6
        case medianOfSix = 3

        var label: String {
            switch self {
            case .previous:    String(localized: "Test précédent")
            case .threeBack:   String(localized: "Il y a 3 tests")
            case .sixBack:     String(localized: "Il y a 6 tests")
            case .medianOfSix: String(localized: "Médiane des 6 derniers")
            }
        }
    }

    struct Outcome {
        let pattern: FatiguePatterns.Pattern?
        let deltas: FatiguePatterns.Deltas
        let referenceLabel: String
    }

    /// Whether the test can be read at all, before any question of a
    /// reference. Both positions are needed: the whole method is the *change*
    /// between them, so one of them missing is not a weaker reading, it is no
    /// reading. Kept apart from `evaluate` so a screen can say which of the two
    /// reasons it has nothing to show — "there is no history yet" and "this
    /// morning is incomplete" look identical from a nil.
    static func isComplete(_ test: HRVTest) -> Bool {
        HeartRateVariability.analyse(rrIntervalsMs: test.supineRRms.map(Double.init)) != nil
            && HeartRateVariability.analyse(rrIntervalsMs: test.standingRRms.map(Double.init)) != nil
    }

    static func thresholds(from settings: AthleteSettings) -> FatiguePatterns.Thresholds {
        var t = FatiguePatterns.Thresholds()
        t.energyCollapseHFSupine = settings.hrvEnergyCollapseHFSupine
        t.energyCollapseLFStanding = settings.hrvEnergyCollapseLFStanding
        t.acuteStressLFSupine = settings.hrvAcuteStressLFSupine
        t.acuteStressLFStanding = settings.hrvAcuteStressLFStanding
        t.activationBrakeHFSupine = settings.hrvActivationBrakeHFSupine
        t.activationBrakeHFStanding = settings.hrvActivationBrakeHFStanding
        t.extremeFatigueHFSupine = settings.hrvExtremeFatigueHFSupine
        t.peripheralRegulationLFStanding = settings.hrvPeripheralRegulationLFStanding
        t.smallBasePower = settings.hrvSmallBasePower
        return t
    }

    /// `earlier` must be ordered oldest-first and exclude the test being read.
    static func evaluate(
        current: HRVTest,
        earlier: [HRVTest],
        settings: AthleteSettings
    ) -> Outcome? {
        guard let currentSupine = powers(current.supineRRms),
              let currentStanding = powers(current.standingRRms)
        else { return nil }

        let mode = Reference(rawValue: settings.hrvReferenceMode) ?? .medianOfSix
        guard let (refSupine, refStanding) = reference(mode, from: earlier) else { return nil }

        let t = thresholds(from: settings)
        guard let deltas = FatiguePatterns.deltas(
            currentSupine: currentSupine, currentStanding: currentStanding,
            referenceSupine: refSupine, referenceStanding: refStanding,
            thresholds: t
        ) else { return nil }

        return Outcome(
            pattern: FatiguePatterns.evaluate(deltas, thresholds: t),
            deltas: deltas,
            referenceLabel: mode.label
        )
    }

    // MARK: -

    private static func powers(_ intervals: [Int]) -> FatiguePatterns.Powers? {
        guard let result = HeartRateVariability.analyse(rrIntervalsMs: intervals.map(Double.init))
        else { return nil }
        return .init(lf: result.lf, hf: result.hf)
    }

    private static func reference(
        _ mode: Reference, from earlier: [HRVTest]
    ) -> (FatiguePatterns.Powers, FatiguePatterns.Powers)? {
        // Oldest-first in, most-recent-first here: "N-1" is the last one.
        let recent = earlier.reversed().map { $0 }

        switch mode {
        case .previous, .threeBack, .sixBack:
            let index = [Reference.previous: 0, .threeBack: 2, .sixBack: 5][mode] ?? 0
            guard recent.indices.contains(index),
                  let supine = powers(recent[index].supineRRms),
                  let standing = powers(recent[index].standingRRms)
            else { return nil }
            return (supine, standing)

        case .medianOfSix:
            // The median of what exists, up to six. Steadier than any single
            // morning, which is the point: one bad night should not redefine
            // the baseline every measurement is read against.
            let six = recent.prefix(6)
            let supines = six.compactMap { powers($0.supineRRms) }
            let standings = six.compactMap { powers($0.standingRRms) }
            guard !supines.isEmpty, !standings.isEmpty else { return nil }
            return (
                .init(lf: median(supines.map(\.lf)), hf: median(supines.map(\.hf))),
                .init(lf: median(standings.map(\.lf)), hf: median(standings.map(\.hf)))
            )
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
