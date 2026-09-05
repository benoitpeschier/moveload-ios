import SwiftUI
import SwiftData
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
    @Environment(\.scenePhase) private var scenePhase

    @State private var recorder: HRVTestRecorder?
    @State private var answers: [Int] = []
    @State private var savedTest: HRVTest?
    @State private var errorMessage: String?
    @Query(sort: \HRVTest.date) private var allTests: [HRVTest]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding()
            // Content narrower than the screen is centred by the ScrollView,
            // which carries the large title with it and clips its left edge —
            // the missing "H" of HRV during the timer was the visible half of
            // that. Every phase now fills the width and stays put.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("HRV")
        // Refreshed when the tab is opened rather than at launch: this is the
        // only screen the thresholds affect, and it is opened once a morning.
        .task {
            await appEnvironment.refreshHRVThresholds()
            await appEnvironment.refreshCoachNotes()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { recorder?.noteBackgrounded() }
        }
        // Held on the environment so that backgrounding the app does not hand
        // the sensor back mid-test — see MoveLoadApp.
        .onChange(of: recorder?.phase) { _, _ in
            appEnvironment.hrvTestInProgress = recorder?.isRunning ?? false
        }
    }

    @ViewBuilder private var content: some View {
        if let savedTest {
            saved(savedTest)
        } else {
            switch recorder?.phase ?? .idle {
            case .idle:            introduction
            case .connecting:      waiting
            case .supine:          timerCard(title: "Allongé", instruction: "Reste immobile, respire normalement.")
            case .standing:        timerCard(title: "Debout", instruction: "Debout, immobile.")
            case .finished:        questionnaire
            case .failed(let why): failure(why)
            }
        }
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

            // The one thing this screen has to say that the countdown cannot.
            // A stream that stops looks exactly like a stream that continues:
            // the timer runs to the end either way, and the loss only becomes
            // visible ten minutes later, as a series too short to read.
            if let silence = recorder?.secondsWithoutSignal {
                Label {
                    Text("Aucun battement depuis \(Int(silence)) s — vérifie la sangle et son contact avec la peau.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }

            Button("Annuler", role: .destructive) {
                Task { await recorder?.cancel(); recorder = nil }
            }
        }
    }

    /// The questionnaire, and nothing else.
    ///
    /// The figures used to sit above it. They now come after the answers are
    /// in: an athlete who has just read "rMSSD 58 ms, série trop courte"
    /// answers the five questions against that number instead of against how
    /// they feel, and the questionnaire is only worth having as a reading
    /// independent of the measurement — sometimes contradicting it.
    private var questionnaire: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Test terminé").font(.title2.bold())

            // Said rather than left to be discovered: the athlete connected the
            // sensor themselves a moment ago, and a link that closes on its own
            // without a word is the kind of thing that gets reported as a bug.
            if recorder?.didDisconnect == true {
                Label {
                    Text("Capteur déconnecté. Il pourra redémarrer un enregistrement tout seul quand tu remettras la sangle.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                }
                .foregroundStyle(.secondary)
            }

            interruptionNotice

            Text("Questionnaire Wellness")
                .font(.headline)
            Text("McLean et al. (2010) — 1 très mauvais, 5 très bon. Ton coach ne voit que le score, jamais tes réponses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(HRVWellness.items.enumerated()), id: \.offset) { index, item in
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

    /// Why a test may have a hole in it, while the athlete can still act on it.
    ///
    /// Both causes produce the same thing — a series far shorter than the
    /// position it was taken over — and the figures alone cannot tell them
    /// apart, so the recorder reports which one it saw.
    @ViewBuilder private var interruptionNotice: some View {
        if recorder?.wasBackgrounded == true {
            notice("L'app est passée en arrière-plan pendant le test : aucun battement n'est enregistré tant qu'elle n'est pas à l'écran. Laisse l'écran allumé et l'app ouverte, elle empêche la mise en veille.")
        } else if let gap = recorder?.longestSignalGap, gap >= HRVTestRecorder.signalGapSeconds {
            notice("Le signal cardiaque s'est interrompu \(Int(gap)) s pendant le test. Le résultat sera partiel.")
        }
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
    }

    /// The figures, once the answers are in and the test is on disk.
    private func saved(_ test: HRVTest) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Test enregistré").font(.title2.bold())

            HRVTestSummary(
                test: test,
                earlier: allTests.filter { $0.date < test.date },
                settings: appEnvironment.athlete.settings)

            Button("Terminé") { savedTest = nil }
                .buttonStyle(.bordered)
        }
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

    private func startTest() async {
        errorMessage = nil
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else {
            errorMessage = String(localized: "Indisponible avec le capteur simulé.")
            return
        }
        let created = HRVTestRecorder(sensor: movesense)
        recorder = created
        appEnvironment.hrvTestInProgress = true
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
