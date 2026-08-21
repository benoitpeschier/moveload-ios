import SwiftUI
import SwiftData
import PersistenceKit
import SyncKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var settings: AthleteSettings?
    @State private var syncSettings = SyncSettings()
    @State private var isSyncing = false
    @State private var syncStatusMessage: String?

    var body: some View {
        Form {
            if let settings {
                Section {
                    if let serial = appEnvironment.pairedSensorSerial {
                        HStack {
                            Text("Capteur")
                            Spacer()
                            Text(serial).foregroundStyle(.secondary)
                        }
                        Button("Oublier ce capteur", role: .destructive) {
                            appEnvironment.pairedSensorSerial = nil
                        }
                    } else {
                        Text("Aucun capteur appairé")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Capteur appairé")
                } footer: {
                    Text(appEnvironment.pairedSensorSerial == nil
                         ? "Le premier capteur auquel tu te connecteras deviendra le tien. L'app ne parlera qu'à celui-là et refusera d'importer une séance venue d'un autre."
                         : "L'app ne se connecte qu'à ce capteur et refuse d'importer une séance venue d'un autre. Ne l'oublie que si tu changes de capteur : les séances déjà importées ne sont pas touchées.")
                }

                Section("Athlète") {
                    TextField(
                        "Nom affiché",
                        text: Binding(
                            get: { appEnvironment.athlete.name ?? "" },
                            set: { appEnvironment.athlete.name = $0.isEmpty ? nil : $0; save() }
                        )
                    )
                    Picker(
                        "Genre",
                        selection: Binding(
                            get: { settings.gender },
                            set: { settings.gender = $0; save() }
                        )
                    ) {
                        ForEach(Gender.allCases, id: \.self) { gender in
                            Text(genderLabel(gender)).tag(gender)
                        }
                    }
                }

                Section("Zones cardio (bpm)") {
                    thresholdRow(
                        label: "Seuil I1 / I2",
                        value: Binding(
                            get: { settings.hrThresholdLow },
                            set: { settings.hrThresholdLow = $0; save() }
                        )
                    )
                    thresholdRow(
                        label: "Seuil I2 / I3",
                        value: Binding(
                            get: { settings.hrThresholdHigh },
                            set: { settings.hrThresholdHigh = $0; save() }
                        )
                    )
                }

                Section("Zones mécaniques (% du record 45 s)") {
                    percentRow(
                        label: "Zone 1 / 2",
                        value: Binding(
                            get: { settings.mechZonePercentLow },
                            set: { settings.mechZonePercentLow = $0; save() }
                        )
                    )
                    percentRow(
                        label: "Zone 2 / 3",
                        value: Binding(
                            get: { settings.mechZonePercentHigh },
                            set: { settings.mechZonePercentHigh = $0; save() }
                        ),
                        upperBound: 2.0
                    )
                    HStack {
                        Text("Ancre confirmée")
                        Spacer()
                        Text(String(format: "%.2f m/s²", settings.confirmedMech45sAnchor))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Historique des records") {
                    Stepper(
                        "Sur \(settings.recordsHistoryValue) \(unitLabel(settings.recordsHistoryUnit))",
                        value: Binding(
                            get: { settings.recordsHistoryValue },
                            set: { settings.recordsHistoryValue = $0; save() }
                        ),
                        in: 1...365
                    )
                    Picker(
                        "Unité",
                        selection: Binding(
                            get: { settings.recordsHistoryUnit },
                            set: { settings.recordsHistoryUnit = $0; save() }
                        )
                    ) {
                        ForEach(HistoryUnit.allCases, id: \.self) { unit in
                            Text(unitLabel(unit)).tag(unit)
                        }
                    }
                }

                Section("Capteur") {
                    Text("Movesense Flash (Bluetooth)")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Link(destination: URL(string: "https://benoitpeschier.github.io/appmoveload/guide.html#athlete")!) {
                        Label("Mode d'emploi", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    TextField(
                        "Code d'équipe",
                        text: Binding(
                            get: { syncSettings.teamCode },
                            set: { syncSettings.teamCode = $0; saveSyncSettings() }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "ID de projet Firebase",
                        text: Binding(
                            get: { syncSettings.projectID },
                            set: { syncSettings.projectID = $0; saveSyncSettings() }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "Clé API Web",
                        text: Binding(
                            get: { syncSettings.webAPIKey },
                            set: { syncSettings.webAPIKey = $0; saveSyncSettings() }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        Task { await syncNow() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Text("Synchroniser maintenant")
                        }
                    }
                    .disabled(isSyncing || !syncSettings.isConfigured)

                    if let syncStatusMessage {
                        Text(syncStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Synchronisation")
                } footer: {
                    Text("Relie cet appareil à la webapp coach. Le code d'équipe doit être identique sur tous les téléphones et dans l'URL de la webapp.")
                }
            }
        }
        .navigationTitle("Réglages")
        .task {
            settings = appEnvironment.athlete.settings
            syncSettings = appEnvironment.syncSettingsStore.load() ?? SyncSettings()
        }
    }

    private func saveSyncSettings() {
        appEnvironment.syncSettingsStore.save(syncSettings)
    }

    private func syncNow() async {
        isSyncing = true
        syncStatusMessage = nil
        do {
            try await appEnvironment.syncAllSessionsNow()
            syncStatusMessage = "Synchronisé à \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            syncStatusMessage = "Échec : \(error.localizedDescription)"
        }
        isSyncing = false
    }

    private func thresholdRow(label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("bpm", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
        }
    }

    private func percentRow(label: String, value: Binding<Double>, upperBound: Double = 0.99) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(value.wrappedValue * 100)) %")
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: 0.1...upperBound, step: 0.05)
                .labelsHidden()
        }
    }

    private func genderLabel(_ gender: Gender) -> String {
        switch gender {
        case .male: "Homme"
        case .female: "Femme"
        }
    }

    private func unitLabel(_ unit: HistoryUnit) -> String {
        switch unit {
        case .days: "jours"
        case .weeks: "semaines"
        case .months: "mois"
        }
    }

    private func save() {
        try? appEnvironment.modelContext.save()
    }
}
