import SwiftUI
import SwiftData
import PersistenceKit
import SyncKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var settings: AthleteSettings?
    @State private var syncSettings = SyncSettings()
    @State private var showScanner = false
    @State private var scanErrorMessage: String?
    @State private var isSyncing = false
    @State private var syncStatusMessage: String?
    @State private var account: AuthAccount?

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
                            set: { settings.hrThresholdLow = $0; saveAndRecompute() }
                        )
                    )
                    thresholdRow(
                        label: "Seuil I2 / I3",
                        value: Binding(
                            get: { settings.hrThresholdHigh },
                            set: { settings.hrThresholdHigh = $0; saveAndRecompute() }
                        )
                    )
                }

                Section {
                    percentRow(
                        label: "Zone 1 / 2",
                        value: Binding(
                            get: { settings.mechZonePercentLow },
                            set: { settings.mechZonePercentLow = $0; saveAndRecompute() }
                        )
                    )
                    percentRow(
                        label: "Zone 2 / 3",
                        value: Binding(
                            get: { settings.mechZonePercentHigh },
                            set: { settings.mechZonePercentHigh = $0; saveAndRecompute() }
                        ),
                        upperBound: 2.0
                    )
                    HStack {
                        Text("Référence 45 s")
                        Spacer()
                        Text("\(settings.confirmedMech45sAnchor.accelerationLabel) m/s²")
                            .foregroundStyle(.secondary)
                    }

                    // The proposal at import happens once and is easy to miss.
                    // Without this the athlete keeps a reference lower than
                    // something they have already done, and every zone since
                    // reads a notch too hard, with nothing on screen saying so.
                    if let better = appEnvironment.recordBeyondConfirmedAnchor {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ta séance du \(better.session.startDate.formatted(date: .abbreviated, time: .omitted)) atteint \(better.peak.accelerationLabel) m/s², au-dessus de ta référence actuelle.")
                                .font(.footnote)
                            Button("Adopter \(better.peak.accelerationLabel) comme référence") {
                                adoptRecord(better)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Zones mécaniques")
                } footer: {
                    Text("Les seuils sont une part de ta référence 45 s confirmée. Ils s'appliquent à une moyenne glissante de 15 secondes, pas à l'accélération instantanée — c'est pourquoi ils valent 35 et 55 % et non 70 et 90. Modifier un pourcentage recalcule aussitôt toutes tes séances : c'est la définition des zones qui change, elle doit être la même partout.")
                }

                Section {
                    Button("Recalculer l'historique") {
                        appEnvironment.recomputeStoredSessions()
                    }
                } footer: {
                    Text("Changer de référence ne touche pas aux séances déjà enregistrées : elles gardent celle avec laquelle elles ont été lues, sinon une séance dure d'il y a six mois deviendrait facile le jour où tu progresses. À n'utiliser que si la référence était fausse, pas quand elle monte.")
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
                    NavigationLink {
                        AccountView(account: account) { account = $0 }
                    } label: {
                        if let account, !account.isAnonymous {
                            LabeledContent("Compte", value: account.email ?? "")
                        } else {
                            Label("Créer un compte ou se connecter", systemImage: "person.crop.circle")
                        }
                    }
                    .disabled(!syncSettings.isConfigured)
                } header: {
                    Text("Compte")
                } footer: {
                    if syncSettings.isConfigured {
                        Text("Un compte vous rattache à vos données plutôt qu'à ce téléphone : vous les retrouvez après un changement d'appareil, et le coach pourra vous inviter dans une équipe. Sans compte, tout continue de fonctionner, mais seulement ici.")
                    } else {
                        Text("Renseignez d'abord la synchronisation ci-dessous : le compte est créé sur le projet Firebase de l'équipe.")
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
                        scanErrorMessage = nil
                        showScanner = true
                    } label: {
                        Label("Scanner un QR code", systemImage: "qrcode.viewfinder")
                    }

                    if syncSettings.isConfigured {
                        NavigationLink {
                            SyncQRCodeView(settings: syncSettings)
                        } label: {
                            Label("Partager ces réglages", systemImage: "qrcode")
                        }
                    }

                    if let scanErrorMessage {
                        Text(scanErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

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
                    Text("Relie cet appareil à la webapp coach. Le code d'équipe doit être identique sur tous les téléphones et dans l'URL de la webapp. Le plus simple est de scanner le QR code d'un appareil déjà configuré plutôt que de recopier les trois valeurs.")
                }
            }
        }
        .navigationTitle("Réglages")
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { payload in
                    showScanner = false
                    // Refuse anything that is not a complete MoveLoad payload
                    // rather than half-filling the fields: a configuration that
                    // looks set up and never syncs is harder to diagnose than
                    // one that is plainly empty.
                    guard let scanned = SyncSettings(shareablePayload: payload) else {
                        scanErrorMessage = String(localized: "Ce QR code n'est pas un code de réglages MoveLoad. Rien n'a été modifié.")
                        return
                    }
                    syncSettings = scanned
                    saveSyncSettings()
                    scanErrorMessage = nil
                }
                .ignoresSafeArea()
                .navigationTitle("Scanner le QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { showScanner = false }
                    }
                }
            }
        }
        .task {
            settings = appEnvironment.athlete.settings
            syncSettings = appEnvironment.syncSettingsStore.load() ?? SyncSettings()
            account = await appEnvironment.syncService.currentAccount()
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
            syncStatusMessage = String(localized: "Synchronisé à \(Date().formatted(date: .omitted, time: .shortened))")
        } catch {
            syncStatusMessage = String(localized: "Échec : \(error.localizedDescription)")
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

    /// Steps whole percents, and stores the rounded result.
    ///
    /// Stepping a Double by 0.05 drifts: seven steps down from 0.70 lands on
    /// 0.34999999999999987, which `Int(_ * 100)` truncates to 34 %. The athlete
    /// then cannot reach 35 at all, however many times they press. Working in
    /// whole percents and converting once removes both the drift and the
    /// coarseness.
    private func percentRow(label: String, value: Binding<Double>, upperBound: Double = 0.99) -> some View {
        let percent = Binding<Int>(
            get: { Int((value.wrappedValue * 100).rounded()) },
            set: { value.wrappedValue = Double($0) / 100 }
        )
        return HStack {
            Text(label)
            Spacer()
            Text("\(percent.wrappedValue) %")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Stepper("", value: percent, in: 10...Int((upperBound * 100).rounded()), step: 1)
                .labelsHidden()
        }
    }

    private func genderLabel(_ gender: Gender) -> String {
        switch gender {
        case .male: String(localized: "Homme")
        case .female: String(localized: "Femme")
        }
    }

    private func unitLabel(_ unit: HistoryUnit) -> String {
        switch unit {
        case .days: String(localized: "jours")
        case .weeks: String(localized: "semaines")
        case .months: String(localized: "mois")
        }
    }

    private func save() {
        try? appEnvironment.modelContext.save()
    }

    /// For settings the stored figures were computed against. Zone times are
    /// worked out from the signal when a session is imported, so moving a
    /// threshold afterwards leaves every stored session describing boundaries
    /// that no longer exist.
    private func saveAndRecompute() {
        save()
        appEnvironment.recomputeStoredSessions()
    }

    /// Adopts a reference the history already justifies. Forward-only, like
    /// every other change of reference: the sessions behind it keep what they
    /// were read with, and `Recalculer l'historique` is there for the case
    /// where the reference was simply wrong.
    private func adoptRecord(_ record: (session: Session, peak: Double)) {
        try? appEnvironment.confirmMechanicalZoneUpdate(
            newAnchor: record.peak, sessionID: record.session.id)
        settings = appEnvironment.athlete.settings
    }
}
