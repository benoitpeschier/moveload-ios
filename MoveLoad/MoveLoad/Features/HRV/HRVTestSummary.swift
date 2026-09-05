import SwiftUI
import SwiftData
import AnalysisEngine
import PersistenceKit

/// Everything one morning's test has to say, in one block.
///
/// Shared by the screen that follows the questionnaire and by the screen a test
/// in the history opens: a morning read two days later must show what it showed
/// the day it was taken, and two renderings of the same figures would drift.
struct HRVTestSummary: View {
    let test: HRVTest
    /// Oldest-first, and excluding `test` itself — what the morning is read
    /// against.
    let earlier: [HRVTest]
    let settings: AthleteSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let supine = analyse(test.supineRRms) {
                measures("Allongé", supine)
            } else {
                missing("Allongé")
            }

            if let standing = analyse(test.standingRRms) {
                measures("Debout", standing)
            } else {
                // Said rather than left out. A section that simply disappears
                // reads as a display bug, and on 2026-09-05 that is exactly how
                // an empty standing position was discovered — by its absence.
                missing("Debout")
            }

            pattern

            if let score = test.wellnessScore {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Questionnaire Wellness").font(.headline)
                    Text("\(score) %").font(.title3.weight(.medium)).monospacedDigit()
                    answers
                }
            }
        }
    }

    // MARK: - Measures

    private func analyse(_ intervals: [Int]) -> HeartRateVariability.Result? {
        HeartRateVariability.analyse(rrIntervalsMs: intervals.map(Double.init))
    }

    private func measures(_ title: LocalizedStringKey, _ result: HeartRateVariability.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            // Formatted rather than String(format:) throughout: "%.2f" writes
            // a dot in every locale, so LF/HF read "1.90" inside French text,
            // and the two lines carrying words were never translated at all —
            // an English reader was told about "battements".
            row("FC moyenne", "\(whole(result.meanHRbpm)) bpm")
            // Shown because it is what decides the reliability flag below —
            // the engine measures a position by the sum of its intervals, and
            // it needs 210 s of them after trimming.
            row("Durée analysée", String(localized: "\(whole(result.durationSeconds)) s · \(result.beatCount) battements"))
            row("rMSSD", "\(whole(result.rmssdMs)) ms")
            row("Puissance totale", "\(whole(result.totalPower)) ms²")
            row("LF / HF", result.lfOverHf.formatted(.number.precision(.fractionLength(2))))
            if !result.isFrequencyDomainReliable {
                Text("Série trop courte pour que le spectre soit fiable.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if result.correctedFraction > 0 {
                Text("\(whole(result.correctedFraction * 100)) % des battements corrigés")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func missing(_ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text("Pas de données exploitables pour cette position.")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    private func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// The value is a plain String: "48 bpm" and "934 ms²" are the same in
    /// both languages, and a catalogue entry per unit is noise. Only the two
    /// values that carry a word go through the catalogue.
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: - Pattern

    private var outcome: HRVVerdict.Outcome? {
        guard let settings else { return nil }
        return HRVVerdict.evaluate(current: test, earlier: earlier, settings: settings)
    }

    /// The reading, named and nothing else — the same as the history screen.
    /// No thresholds, no deltas: those are the coach's, read against a whole
    /// squad and a season.
    @ViewBuilder private var pattern: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Motif").font(.headline)
            if let outcome {
                HStack(spacing: 8) {
                    Circle()
                        .fill(outcome.pattern?.colour ?? FatigueBalance.colour)
                        .frame(width: 10, height: 10)
                    Text(outcome.pattern?.name ?? FatigueBalance.name)
                        .font(.callout).fontWeight(.medium)
                }
                Text("À faire valider par ton coach : c'est un repère, pas un diagnostic.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !HRVVerdict.isComplete(test) {
                Text("Ce test est incomplet : sans les deux positions, le motif ne peut pas être calculé.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Il faut au moins deux tests pour situer le matin par rapport aux précédents.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Wellness

    /// The athlete's own answers, on the athlete's own phone. The coach gets
    /// the score alone — see HRVTest.wellnessAnswers.
    @ViewBuilder private var answers: some View {
        if test.wellnessAnswers.count == HRVWellness.items.count {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(HRVWellness.items.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text(item).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(test.wellnessAnswers[index]) / 5").monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// McLean et al. (2010), in its original order. Named in the interface rather
/// than called "the five questions": a named instrument invites the athlete to
/// answer it as one, and the provenance stops someone rewording the items
/// later.
enum HRVWellness {
    static var items: [String] {
        [
            String(localized: "Fatigue"),
            String(localized: "Qualité du sommeil"),
            String(localized: "Courbatures"),
            String(localized: "Stress"),
            String(localized: "Humeur"),
        ]
    }
}

/// One saved test, opened from the history.
struct HRVTestDetailView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    let test: HRVTest
    @Query(sort: \HRVTest.date) private var allTests: [HRVTest]

    var body: some View {
        ScrollView {
            HRVTestSummary(
                test: test,
                earlier: allTests.filter { $0.date < test.date },
                settings: appEnvironment.athlete.settings)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(test.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}
