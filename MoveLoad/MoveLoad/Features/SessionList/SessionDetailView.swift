import SwiftUI
import SwiftData
import PersistenceKit
import MoveLoadCore

struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    let session: Session

    @State private var records: [MechanicalWindow: Double] = [:]
    @State private var pendingAnchor: Double?
    @State private var exportURLs: [URL] = []
    @State private var rpeValue: Double = 5
    @State private var boatType: BoatType = .k1
    @State private var isTest: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !recordWindows.isEmpty {
                    confettiBanner
                }

                if let pendingAnchor {
                    newRecordBanner(anchor: pendingAnchor)
                }

                boatTypeBanner

                perceivedExertionBanner

                ZonePieChartView(title: "Charge cardio", slices: hrSlices)
                ZonePieChartView(title: "Charge mécanique", slices: mechSlices)
                MechanicalCurveChartView(sessionCurve: sessionCurve, records: records)
            }
            .padding()
        }
        .navigationTitle(session.startDate.formatted(date: .abbreviated, time: .shortened))
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
            rpeValue = Double(session.perceivedExertion ?? 5)
            loadRecords()
            exportURLs = (try? CSVExporter.exportSession(session)) ?? []
        }
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
                HStack(spacing: 8) {
                    Image(systemName: isTest ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isTest ? Color.accentColor : .secondary)
                    Text("Séance de test (conditions standardisées)")
                        .foregroundStyle(.primary)
                        .font(.subheadline)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bannerBackground)
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
            Text("Nouveau record 45 s : \(String(format: "%.2f", anchor)) m/s²")
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

    private func loadRecords() {
        records = (try? appEnvironment.liveRecords()) ?? [:]
        guard let settings = appEnvironment.athlete.settings,
              let peak45 = sessionCurve[.s45] ?? nil,
              peak45 > settings.confirmedMech45sAnchor else { return }
        pendingAnchor = peak45
    }
}
