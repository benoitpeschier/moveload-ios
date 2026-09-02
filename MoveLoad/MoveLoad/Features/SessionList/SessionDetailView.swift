import SwiftUI
import SwiftData
import PersistenceKit
import MoveLoadCore
import AnalysisEngine

struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    let session: Session

    @State private var records: [MechanicalWindow: Double] = [:]
    @State private var pendingAnchor: Double?
    @State private var exportURLs: [URL] = []
    @State private var rpeValue: Double = 5
    @State private var boatType: BoatType = .k1
    @State private var isTest: Bool = false
    @State private var isConditioning: Bool = false
    @State private var isConfirmingConditioningChange = false
    @State private var name: String = ""
    /// Read from the raw file rather than stored on the session: the beat
    /// stream is far too large for SwiftData rows, which is why it lives on
    /// disk (see RawSampleFileStore).
    @State private var hrSamples: [HRSample] = []
    @State private var recordEfforts: [RecordEffortSpan] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !isConditioning, !recordWindows.isEmpty {
                    confettiBanner
                }

                if !isConditioning, let pendingAnchor {
                    newRecordBanner(anchor: pendingAnchor)
                }

                nameBanner

                if !isConditioning {
                    boatTypeBanner
                }

                perceivedExertionBanner

                ZonePieChartView(
                    title: String(localized: "Charge cardio"),
                    slices: hrSlices,
                    helpText: ChartHelp.cardioLoad
                )
                if !isConditioning {
                    ZonePieChartView(
                        title: String(localized: "Charge mécanique"),
                        slices: mechSlices,
                        unavailableMessage: mechZonesUnavailableMessage,
                        helpText: ChartHelp.mechanicalLoad(
                            percentLow: appEnvironment.athlete.settings?.mechZonePercentLow ?? 0.35,
                            percentHigh: appEnvironment.athlete.settings?.mechZonePercentHigh ?? 0.55
                        )
                    )
                    TimeAboveAnchorView(
                        seconds: session.secondsAboveAnchor,
                        anchor: session.mechZoneAnchorUsed,
                        countedSeconds: session.mechZone1Seconds + session.mechZone2Seconds + session.mechZone3Seconds
                    )
                    MechanicalCurveChartView(sessionCurve: sessionCurve, records: records)
                }

                if let settings = appEnvironment.athlete.settings {
                    HeartRateCurveChartView(
                        samples: hrSamples,
                        thresholdLow: settings.hrThresholdLow,
                        thresholdHigh: settings.hrThresholdHigh,
                        recordEfforts: recordEfforts
                    )
                }
            }
            .padding()
        }
        .navigationTitle(session.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(items: exportURLs) {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                .disabled(exportURLs.isEmpty)
            }
        }
        .task {
            boatType = session.boatType ?? .k1
            isTest = session.isTest
            isConditioning = session.isConditioning
            name = session.name ?? ""
            rpeValue = Double(session.perceivedExertion ?? 5)
            loadRecords()
            loadHeartRate()
            exportURLs = (try? CSVExporter.exportSession(session)) ?? []
            await loadRecordEfforts()
        }
    }

    private var nameBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nom de la séance")
                .font(.headline)
            TextField(
                session.startDate.formatted(date: .abbreviated, time: .shortened),
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .submitLabel(.done)
            .onSubmit { saveName() }
            // Also save when the field loses focus or the screen goes away,
            // so a name typed without pressing Done isn't quietly lost.
            .onChange(of: name) { _, _ in saveName() }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = trimmed.isEmpty ? nil : trimmed
        guard stored != session.name else { return }
        session.name = stored
        try? appEnvironment.modelContext.save()
        appEnvironment.syncSessionInBackground(session)
    }

    private var boatTypeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Embarcation")
                .font(.headline)
            Picker("Embarcation", selection: $boatType) {
                ForEach(BoatType.allCases, id: \.self) { boat in
                    Text(boat.rawValue).tag(boat)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: boatType) { _, newValue in
                session.boatType = newValue
                try? appEnvironment.modelContext.save()
                appEnvironment.syncSessionInBackground(session)
            }

            Button {
                isTest.toggle()
                session.isTest = isTest
                try? appEnvironment.modelContext.save()
                appEnvironment.syncSessionInBackground(session)
            } label: {
                checkbox(isTest, String(localized: "Séance de test (conditions standardisées)"))
            }
            .buttonStyle(.plain)

            Button {
                isConfirmingConditioningChange = true
            } label: {
                checkbox(isConditioning, String(localized: "Séance PPG (charge cardio uniquement)"))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
        .confirmationDialog(
            isConditioning ? "Reclasser en séance de pagaie ?" : "Marquer comme séance PPG ?",
            isPresented: $isConfirmingConditioningChange,
            titleVisibility: .visible
        ) {
            Button(isConditioning ? "Reclasser en pagaie" : "Marquer PPG") {
                applyConditioningChange(!isConditioning)
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(isConditioning
                 ? "La séance sera relue comme du pagayage : la charge mécanique revient, et la marche et les pauses seront à nouveau écartées du cardio."
                 : "La séance sera relue en cardio seul : la charge mécanique est abandonnée, et la marche, la course et les pauses sont comptées.")
        }
    }

    /// Recompute, don't just hide: the cardiac zones were counted over the
    /// paddling stretches only, and on a run there are none — the walking and
    /// the pauses are the session.
    private func applyConditioningChange(_ newValue: Bool) {
        isConditioning = newValue
        session.isConditioning = newValue
        appEnvironment.reanalyseFromDisk(session)
        loadRecords()
        loadHeartRate()
    }

    private func checkbox(_ isOn: Bool, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
            Text(label)
                .foregroundStyle(.primary)
                .font(.subheadline)
        }
    }

    private var perceivedExertionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Charge globale ressentie")
                    .font(.headline)
                Spacer()
                Text("\(Int(rpeValue)) / 10")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $rpeValue, in: 1...10, step: 1) {
                Text("Charge globale ressentie")
            } minimumValueLabel: {
                Text("1")
            } maximumValueLabel: {
                Text("10")
            }
            .onChange(of: rpeValue) { _, newValue in
                session.perceivedExertion = Int(newValue)
                try? appEnvironment.modelContext.save()
                appEnvironment.syncSessionInBackground(session)
            }
            HStack {
                Text("Facile")
                Spacer()
                Text("Extrêmement difficile")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
    }

    private var bannerBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.systemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.title2.bold())
            Text("Durée : \(Int(session.duration / 60)) min")
                .foregroundStyle(.secondary)
            if session.excludedWalkingSeconds >= 30 {
                Label(
                    "\(Int((session.excludedWalkingSeconds / 60).rounded())) min de marche exclus de l'analyse",
                    systemImage: "figure.walk"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if session.inactiveSeconds >= 30 {
                Label(
                    "\(Int((session.inactiveSeconds / 60).rounded())) min sans effort non comptés dans les zones",
                    systemImage: "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var confettiBanner: some View {
        let labels = recordWindows.map(\.label).joined(separator: ", ")
        return HStack(spacing: 8) {
            Text("🎉")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nouveau record !")
                    .font(.headline)
                Text("Sur \(labels)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private func newRecordBanner(anchor: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nouveau record 45 s : \(anchor.accelerationLabel) m/s²")
                .font(.headline)
            Text("Mettre à jour les zones mécaniques avec cette nouvelle référence ?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Mettre à jour") {
                    try? appEnvironment.confirmMechanicalZoneUpdate(newAnchor: anchor, sessionID: session.id)
                    self.pendingAnchor = nil
                }
                .buttonStyle(.borderedProminent)

                Button("Ignorer") { self.pendingAnchor = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var hrSlices: [ZoneSlice] {
        [
            ZoneSlice(label: "I1", seconds: session.hrZoneI1Seconds, color: .blue),
            ZoneSlice(label: "I2", seconds: session.hrZoneI2Seconds, color: .orange),
            ZoneSlice(label: "I3", seconds: session.hrZoneI3Seconds, color: .red),
        ]
    }

    /// Mechanical zones are percentages of the confirmed 45 s reference, so
    /// with no reference both thresholds sit at zero and every sample lands in
    /// zone 3 — a chart that would read as "the whole session at maximum
    /// intensity" rather than as a missing setting.
    private var mechZonesUnavailableMessage: String? {
        let anchor = session.mechZoneAnchorUsed > 0
            ? session.mechZoneAnchorUsed
            : (appEnvironment.athlete.settings?.confirmedMech45sAnchor ?? 0)
        guard anchor <= 0 else { return nil }
        return String(localized: "Référence 45 s pas encore définie : les zones mécaniques ne peuvent pas être calculées. Elle se règle en confirmant un record 45 s, ou depuis Réglages.")
    }

    private var mechSlices: [ZoneSlice] {
        [
            ZoneSlice(label: "Zone 1", seconds: session.mechZone1Seconds, color: .green),
            ZoneSlice(label: "Zone 2", seconds: session.mechZone2Seconds, color: .yellow),
            ZoneSlice(label: "Zone 3", seconds: session.mechZone3Seconds, color: .purple),
        ]
    }

    private var sessionCurve: [MechanicalWindow: Double?] {
        var curve: [MechanicalWindow: Double?] = [:]
        for point in session.curvePoints {
            if let window = point.window { curve[window] = point.peakValue }
        }
        return curve
    }

    /// Windows where this session's peak currently equals the live record —
    /// i.e. this session presently holds the record for that duration. Uses
    /// exact equality deliberately: `records[window]` is a `max()` over the
    /// same stored values as `sessionCurve[window]`, so when this session is
    /// the max the two are bit-identical, not just numerically close.
    private var recordWindows: [MechanicalWindow] {
        MechanicalWindow.allCases.filter { window in
            guard let peak = sessionCurve[window] ?? nil, let record = records[window] else { return false }
            return peak == record
        }
    }

    private func loadHeartRate() {
        let directory = PersistenceContainer.documentsSessionsDirectory()
            .appendingPathComponent(session.rawSampleDirectory)
        // Absent or unreadable raw files simply mean no curve, not an error
        // worth interrupting the athlete over.
        hrSamples = (try? RawSampleFileStore.read(startDate: session.startDate, from: directory))?.hrSamples ?? []
    }

    /// Locates the record-setting efforts within the recording. Where a peak
    /// happened isn't persisted — only its value is — so it's recomputed from
    /// the raw samples, off the main thread since a long session runs to
    /// hundreds of thousands of them.
    private func loadRecordEfforts() async {
        let windows = recordWindows
        guard !windows.isEmpty else {
            recordEfforts = []
            return
        }
        let directory = PersistenceContainer.documentsSessionsDirectory()
            .appendingPathComponent(session.rawSampleDirectory)
        let startDate = session.startDate

        let spans = await Task.detached(priority: .userInitiated) { () -> [RecordEffortSpan] in
            guard let raw = try? RawSampleFileStore.read(startDate: startDate, from: directory) else { return [] }

            // Must mirror SessionAnalyzer exactly, or the located peaks would
            // belong to a different signal than the reported ones.
            let effort = EffortSignal.dynamic(raw.accelX, sampleRateHz: raw.accelSampleRateHz)
            var keepMask: [Bool]?
            if let axes = raw.axes, axes.count == raw.accelX.count {
                keepMask = GaitDetector.detect(axes: axes, sampleRateHz: raw.accelSampleRateHz).keepMask
            }
            let result = keepMask.map {
                MechanicalCurveAnalyzer.analyze(accelX: effort, sampleRateHz: raw.accelSampleRateHz, keepMask: $0)
            } ?? MechanicalCurveAnalyzer.analyze(accelX: effort, sampleRateHz: raw.accelSampleRateHz)

            return windows.compactMap { window in
                guard let start = result.peakStartSeconds[window] ?? nil else { return nil }
                return RecordEffortSpan(
                    label: window.label,
                    startSeconds: start,
                    durationSeconds: window.seconds
                )
            }
        }.value

        recordEfforts = spans
    }

    private func loadRecords() {
        records = (try? appEnvironment.liveRecords()) ?? [:]
        guard let settings = appEnvironment.athlete.settings,
              let peak45 = sessionCurve[.s45] ?? nil,
              peak45 > settings.confirmedMech45sAnchor else { return }
        pendingAnchor = peak45
    }
}
