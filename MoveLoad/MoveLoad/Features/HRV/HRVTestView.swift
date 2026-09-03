import SwiftUI
import SwiftData
import AnalysisEngine
import MovesenseVendor
import PersistenceKit

/// The morning orthostatic test, start to finish in one screen.
///
/// One screen on purpose: a daily ritual that takes two levels of navigation
/// does not get done, and a HRV series with gaps is worth nothing. The five
/// questions come straight after the measurement for the same reason — asked
/// later they go unanswered.
struct HRVTestView: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var recorder: HRVTestRecorder?
    @State private var answers: [Int] = []
    @State private var savedTest: HRVTest?
    @State private var errorMessage: String?
    @Query(sort: \HRVTest.date) private var allTests: [HRVTest]

    /// McLean et al. (2010), in its original order. Named in the interface
    /// rather than called "the five questions": a named instrument invites the
    /// athlete to answer it as one, and the provenance stops someone rewording
    /// the items later.
    private static let wellnessItems = [
        "Fatigue", "Qualité du sommeil", "Courbatures", "Stress", "Humeur",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch recorder?.phase ?? .idle {
                case .idle:            introduction
                case .connecting:      waiting
                case .supine:          timerCard(title: "Allongé", instruction: "Reste immobile, respire normalement.")
                case .standing:        timerCard(title: "Debout", instruction: "Debout, immobile.")
                case .finished:        results
                case .failed(let why): failure(why)
                }
            }
            .padding()
        }
        .navigationTitle("HRV")
        // Refreshed when the tab is opened rather than at launch: this is the
        // only screen the thresholds affect, and it is opened once a morning.
        .task { await appEnvironment.refreshHRVThresholds() }
    }

    // MARK: - Phases

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test orthostatique")
                .font(.title2.bold())
            Text("Cinq minutes allongé, puis cinq minutes debout. À faire au réveil, avant le café et avant de consulter quoi que ce soit — c'est la régularité qui rend la série lisible, pas la précision d'un matin.")
                .foregroundStyle(.secondary)
            Text("Mets la sangle, connecte le capteur depuis l'onglet Capteur, puis allonge-toi avant de démarrer.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Démarrer le test") {
                Task { await startTest() }
            }
            .buttonStyle(.borderedProminent)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            Divider().padding(.vertical, 8)
            HRVHistoryView()
        }
    }

    private var waiting: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("En attente du signal cardiaque…")
        }
    }

    private func timerCard(title: String, instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(countdown)
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(instruction).foregroundStyle(.secondary)

            if let bpm = recorder?.currentBpm {
                Label("\(Int(bpm.rounded())) bpm", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
            }
            Text("\(beatsSoFar) battements enregistrés")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Annuler", role: .destructive) {
                Task { await recorder?.cancel(); recorder = nil }
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Test terminé").font(.title2.bold())

            verdict

            if let supine = analyse(recorder?.supineRR ?? []) {
                measures("Allongé", supine)
            }
            if let standing = analyse(recorder?.standingRR ?? []) {
                measures("Debout", standing)
            }

            Divider()

            Text("Questionnaire Wellness")
                .font(.headline)
            Text("McLean et al. (2010) — 1 très mauvais, 5 très bon. Ton coach ne voit que le score, jamais tes réponses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(Self.wellnessItems.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item).font(.subheadline)
                    Picker(item, selection: binding(for: index)) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Button("Enregistrer") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(answers.count < 5 || answers.contains(0))
        }
    }

    /// The fatigue reading, or its absence.
    ///
    /// It describes and does not prescribe: it names the physiological picture
    /// and the deltas behind it, never what session to do. That depends on the
    /// week's plan, the water and how the athlete feels, none of which the app
    /// knows.
    @ViewBuilder private var verdict: some View {
        if let settings = appEnvironment.athlete.settings,
           let recorder,
           !allTests.isEmpty {
            // Deliberately without the athlete: this object exists only to
            // carry the intervals into the verdict, it is never inserted, and
            // hanging it off a managed relationship is how SwiftData is
            // persuaded to insert something nobody asked it to — once per body
            // evaluation, which is often.
            let provisional = HRVTest(date: Date())
            let outcome: HRVVerdict.Outcome? = {
                provisional.supineRRms = recorder.supineRR
                provisional.standingRRms = recorder.standingRR
                return HRVVerdict.evaluate(current: provisional, earlier: allTests, settings: settings)
            }()

            if let outcome {
                VStack(alignment: .leading, spacing: 6) {
                    if let pattern = outcome.pattern {
                        Text(pattern.rawValue).font(.headline).foregroundStyle(.orange)
                        Text(pattern.reading).font(.callout)
                    } else {
                        Text("Pas de motif de fatigue").font(.headline)
                    }
                    Text("Référence : \(outcome.referenceLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "HF couché %+.0f %% · LF couché %+.0f %% · HF debout %+.0f %% · LF debout %+.0f %%",
                                outcome.deltas.hfSupine, outcome.deltas.lfSupine,
                                outcome.deltas.hfStanding, outcome.deltas.lfStanding))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if outcome.deltas.restsOnSmallBase {
                        Text("Écarts calculés sur une base faible : un grand pourcentage y est surtout de l'arithmétique.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func measures(_ title: String, _ result: HeartRateVariability.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            row("FC moyenne", String(format: "%.0f bpm", result.meanHRbpm))
            // Shown because it is what decides the reliability flag below —
            // the engine measures a position by the sum of its intervals, and
            // it needs 210 s of them after trimming.
            row("Durée analysée", String(format: "%.0f s · %lld battements", result.durationSeconds, result.beatCount))
            row("rMSSD", String(format: "%.0f ms", result.rmssdMs))
            row("Puissance totale", String(format: "%.0f ms²", result.totalPower))
            row("LF / HF", String(format: "%.2f", result.lfOverHf))
            if !result.isFrequencyDomainReliable {
                Text("Série trop courte pour que le spectre soit fiable.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if result.correctedFraction > 0 {
                Text(String(format: "%.0f %% des battements corrigés", result.correctedFraction * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    private func failure(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Le test n'a pas pu démarrer").font(.headline)
            Text(why).foregroundStyle(.secondary)
            Button("Réessayer") { recorder = nil }
        }
    }

    // MARK: -

    private var countdown: String {
        let remaining = Int((recorder?.secondsRemainingInPhase ?? 0).rounded(.up))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private var beatsSoFar: Int {
        (recorder?.supineRR.count ?? 0) + (recorder?.standingRR.count ?? 0)
    }

    private func binding(for index: Int) -> Binding<Int> {
        Binding(
            get: { answers.indices.contains(index) ? answers[index] : 0 },
            set: { newValue in
                while answers.count < 5 { answers.append(0) }
                answers[index] = newValue
            }
        )
    }

    private func analyse(_ intervals: [Int]) -> HeartRateVariability.Result? {
        HeartRateVariability.analyse(rrIntervalsMs: intervals.map(Double.init))
    }

    private func startTest() async {
        errorMessage = nil
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else {
            errorMessage = String(localized: "Indisponible avec le capteur simulé.")
            return
        }
        let created = HRVTestRecorder(sensor: movesense)
        recorder = created
        await created.start()
    }

    private func save() {
        guard let recorder else { return }
        let test = HRVTest(athlete: appEnvironment.athlete, date: Date())
        test.supineRRms = recorder.supineRR
        test.standingRRms = recorder.standingRR
        test.wellnessAnswers = answers
        appEnvironment.modelContext.insert(test)
        try? appEnvironment.modelContext.save()
        appEnvironment.syncHRVTestInBackground(test)
        savedTest = test
        self.recorder = nil
        answers = []
    }
}
