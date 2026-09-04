import SwiftUI
import SwiftData
import AnalysisEngine
import Charts
import PersistenceKit

/// Past tests, and the trend across them.
///
/// A single morning's figures mean almost nothing — HRV is read against an
/// athlete's own history, not against a population. This is the view that makes
/// the daily ritual worth doing.
struct HRVHistoryView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query(sort: \HRVTest.date, order: .reverse) private var tests: [HRVTest]
    @State private var testPendingDelete: HRVTest?
    @State private var deleteErrorMessage: String?

    var body: some View {
        content
            .alert(
                "Supprimer ce test ?",
                isPresented: Binding(
                    get: { testPendingDelete != nil },
                    set: { if !$0 { testPendingDelete = nil } }
                )
            ) {
                Button("Annuler", role: .cancel) {}
                Button("Supprimer", role: .destructive) {
                    guard let test = testPendingDelete else { return }
                    testPendingDelete = nil
                    Task { await delete(test) }
                }
            } message: {
                Text("Le test disparaîtra aussi du tableau de bord du coach. Les tests d'essai faussent la médiane contre laquelle les suivants sont lus.")
            }
            .alert(
                "Suppression impossible",
                isPresented: Binding(
                    get: { deleteErrorMessage != nil },
                    set: { if !$0 { deleteErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage ?? "")
            }
    }

    /// Retracted from the coach's dashboard first — see AppEnvironment. The
    /// error is surfaced rather than swallowed: a test that stays visible to
    /// the coach after being deleted here is the failure worth knowing about.
    private func delete(_ test: HRVTest) async {
        do {
            try await appEnvironment.deleteHRVTest(test)
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder private var content: some View {
        if tests.isEmpty {
            ContentUnavailableView(
                "Pas encore de test",
                systemImage: "heart.text.square",
                description: Text("Les tests du matin s'accumulent ici. C'est leur suite qui a du sens, pas un matin isolé.")
            )
        } else {
            VStack(alignment: .leading, spacing: 24) {
                trend
                patterns
                list
            }
        }
    }

    // MARK: -

    /// One row per test, both positions, for the charts below.
    private struct Point: Identifiable {
        let id: Date
        let date: Date
        let supine: HeartRateVariability.Result
        let standing: HeartRateVariability.Result?
    }

    private var points: [Point] {
        tests.reversed().compactMap { test in
            guard let supine = HeartRateVariability.analyse(
                rrIntervalsMs: test.supineRRms.map(Double.init)) else { return nil }
            return Point(
                id: test.date, date: test.date, supine: supine,
                standing: HeartRateVariability.analyse(
                    rrIntervalsMs: test.standingRRms.map(Double.init)))
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Allongé") {
                chart("FC et rMSSD", series: [
                    ("FC (bpm)", { $0.supine.meanHRbpm }),
                    ("rMSSD (ms)", { $0.supine.rmssdMs }),
                ])
                chart("LF et HF (ms²)", series: [
                    ("LF", { $0.supine.lf }),
                    ("HF", { $0.supine.hf }),
                ])
            }
            section("Debout") {
                chart("LF et FC", series: [
                    ("LF (ms²)", { $0.standing?.lf ?? 0 }),
                    ("FC (bpm)", { $0.standing?.meanHRbpm ?? 0 }),
                ])
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }

    /// A morning is a day, so the axis is a day.
    ///
    /// The default date axis reaches for hours as soon as two tests fall close
    /// together, and "06:40" on the x-axis of a series taken one morning per
    /// day says nothing anyone needs.
    private func chart(_ title: LocalizedStringKey,
                       series: [(String, (Point) -> Double)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach(series, id: \.0) { name, value in
                    ForEach(points) { point in
                        LineMark(x: .value("Jour", point.date, unit: .day),
                                 y: .value("Valeur", value(point)))
                            .foregroundStyle(by: .value("Mesure", name))
                        PointMark(x: .value("Jour", point.date, unit: .day),
                                  y: .value("Valeur", value(point)))
                            .foregroundStyle(by: .value("Mesure", name))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 160)
        }
    }

    // MARK: - Fatigue patterns

    private var outcome: HRVVerdict.Outcome? {
        guard let settings = appEnvironment.athlete.settings,
              let current = tests.first else { return nil }
        return HRVVerdict.evaluate(
            current: current, earlier: Array(tests.dropFirst()).reversed(), settings: settings)
    }

    /// The reading, named and nothing else.
    ///
    /// No thresholds, no deltas, no editing: those belong to the coach, who
    /// reads them against a whole squad and a season. Here the athlete gets the
    /// name of what the morning looks like and the instruction to take it to
    /// their coach — which is the only action this screen should produce.
    private var patterns: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Motif du jour").font(.headline)

            if let outcome {
                HStack(spacing: 8) {
                    Circle()
                        .fill(outcome.pattern?.colour ?? FatigueBalance.colour)
                        .frame(width: 10, height: 10)
                    Text(outcome.pattern?.name ?? FatigueBalance.name)
                        .font(.callout).fontWeight(.medium)
                }

                DisclosureGroup("Les cinq motifs") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(FatiguePatterns.Pattern.allCases, id: \.self) { pattern in
                            HStack(spacing: 8) {
                                Circle().fill(pattern.colour).frame(width: 8, height: 8)
                                Text(pattern.name).font(.callout)
                                Spacer()
                            }
                        }
                        HStack(spacing: 8) {
                            Circle().fill(FatigueBalance.colour).frame(width: 8, height: 8)
                            Text(FatigueBalance.name).font(.callout)
                            Spacer()
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
            } else {
                Text("Il faut au moins deux tests pour situer le matin par rapport aux précédents.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Label {
                Text("Quel que soit le motif, fais-le valider par ton coach : ce sont des repères, pas un diagnostic, et la décision d'entraînement lui revient.")
                    .font(.caption)
            } icon: {
                Image(systemName: "person.2")
            }
            .foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tests").font(.headline)
            Text("Appui long sur un test pour le supprimer.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tests) { test in
                row(test)
                    // A context menu rather than a swipe: this is a VStack, not
                    // a List, and swipe actions do not exist outside one.
                    .contextMenu {
                        Button(role: .destructive) {
                            testPendingDelete = test
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                Divider()
            }
        }
    }

    private func row(_ test: HRVTest) -> some View {
        let supine = HeartRateVariability.analyse(rrIntervalsMs: test.supineRRms.map(Double.init))
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(test.date.formatted(date: .abbreviated, time: .shortened))
                if let score = test.wellnessScore {
                    Text("Wellness \(score) %").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let supine {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "rMSSD %.0f ms", supine.rmssdMs)).monospacedDigit()
                    Text(String(format: "%.0f bpm", supine.meanHRbpm))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}
