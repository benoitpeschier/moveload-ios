import SwiftUI
import SensorKit
import MoveLoadCore
import MovesenseVendor
import UniformTypeIdentifiers

struct RecordingView: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var connectionState: SensorConnectionState = .disconnected
    @State private var isScanning = false
    @State private var isLogging = false
    @State private var isTogglingLogging = false
    @State private var isRefreshingEntries = false
    @State private var entries: [LogbookEntryInfo] = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var errorMessage: String?
    @State private var isErasingMemory = false
    @State private var showEraseConfirmation = false
    @State private var showDfuConfirmation = false
    @State private var isEnteringDfu = false
    @State private var hrProbeReference: UInt8?
    @State private var hrProbeLines: [String] = []
    @State private var isRecoveringHidden = false
    @State private var recoveryStatus: String?
    @State private var hasUnlistedEntries = false
    @State private var showEraseAfterImportPrompt = false
    /// Logbook ids downloaded and imported since this screen appeared — the
    /// only trustworthy evidence that erasing the sensor loses nothing.
    @State private var importedThisRun: Set<String> = []
    @State private var isImportingShowcase = false
    /// Everything that answered the last scan, kept only to let the athlete
    /// pick their own sensor the first time.
    @State private var discoveredSensors: [DiscoveredSensor] = []
    @State private var showSensorPicker = false
    @State private var isImportInProgress = false
    @State private var importStatusMessage: String?
    @State private var diagnostics: SensorDiagnostics?
    @State private var isReadingDiagnostics = false

    var body: some View {
        List {
            Section("Connexion") {
                connectionRow
                firmwareRow
                batteryRow
            }

            if case .connected = connectionState {
                diagnosticsSection
            }

            if case .connected = connectionState {
                Section("Enregistrement") {
                    if isTogglingLogging {
                        ProgressView()
                    } else {
                        Button(isLogging ? "Arrêter l'enregistrement" : "Démarrer l'enregistrement") {
                            Task { await toggleLogging() }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Rafraîchir la liste")
                        Spacer()
                        if isRefreshingEntries {
                            ProgressView()
                        } else {
                            Button("Rafraîchir") { Task { await refreshEntries() } }
                        }
                    }
                }

                if let pressure = memoryPressure {
                    Section {
                        memoryWarning(pressure)
                    }
                }

                Section {
                    if entries.isEmpty {
                        Text("Aucun enregistrement").foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                } header: {
                    Text("Enregistrements sur le capteur")
                } footer: {
                    if let line = lastTransferLine {
                        Text(line).monospacedDigit()
                    }
                }

                Section {
                    if isRecoveringHidden {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView()
                            Text(recoveryStatus ?? String(localized: "Recherche…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Récupérer les séances masquées") {
                            Task { await recoverHiddenSessions() }
                        }
                        if let recoveryStatus {
                            Text(recoveryStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    if hasUnlistedEntries {
                        Label("Enregistrements non listés", systemImage: "exclamationmark.triangle")
                    }
                } footer: {
                    Text(hasUnlistedEntries
                        ? "Le capteur signale qu'il contient d'autres enregistrements que sa liste ne peut pas afficher (elle plafonne à quatre). Ceci va les chercher directement et les importe."
                        : "Le capteur ne sait afficher que quatre enregistrements à la fois. Ceci va chercher directement ceux qui suivent, et les importe.")
                }

                Section {
                    if isErasingMemory {
                        ProgressView()
                    } else {
                        Button("Effacer toute la mémoire du capteur", role: .destructive) {
                            showEraseConfirmation = true
                        }
                        .disabled(entries.isEmpty)
                    }
                } footer: {
                    Text("Le capteur ne permet pas de supprimer une séance individuellement : ceci efface tout le journal d'un coup. Irréversible.")
                }

                // Temporary: the HRV work needs to know what a live /Meas/HR
                // notification actually contains before anything can decode it.
                Section {
                    Button(hrProbeReference == nil
                           ? "Écouter le cardio en direct (diagnostic)"
                           : "Arrêter l'écoute") {
                        Task { await toggleHeartRateProbe() }
                    }
                    ForEach(hrProbeLines, id: \.self) { line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("Vérifie que le flux d'intervalles R-R arrive et qu'il est cohérent, avant que le test HRV s'appuie dessus. Chaque ligne est un battement.")
                }

                Section {
                    if isEnteringDfu {
                        ProgressView()
                    } else {
                        Button("Passer en mode mise à jour (DFU)") {
                            showDfuConfirmation = true
                        }
                    }
                } footer: {
                    Text("En fonctionnement normal, le capteur n'expose pas le service de mise à jour : nRF Connect répond « Not Supported ». Ceci l'y bascule. Il se déconnecte, réapparaît sous un autre nom, et n'enregistre plus tant qu'une mise à jour n'est pas envoyée ou qu'il n'est pas redémarré en le sortant de la sangle.")
                }
            }

            Section {
                Button {
                    isImportingShowcase = true
                } label: {
                    if isImportInProgress {
                        ProgressView()
                    } else {
                        Text("Importer depuis Showcase")
                    }
                }
                .disabled(isImportInProgress)

                if let importStatusMessage {
                    Text(importStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Import manuel")
            } footer: {
                Text("En attendant que l'enregistrement direct fonctionne : enregistre la séance avec l'app Movesense Showcase, exporte les fichiers acc_stream.json et heartRate_stream.json, puis sélectionne-les ici (les deux à la fois).")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Capteur")
        .task { await observeConnection() }
        .fileImporter(
            isPresented: $isImportingShowcase,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleShowcaseImport(result) }
        }
        .sheet(isPresented: $showSensorPicker) {
            sensorPicker
        }
        .confirmationDialog(
            eraseConfirmationTitle,
            isPresented: $showEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Effacer définitivement", role: .destructive) {
                Task { await eraseMemory() }
            }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog(
            "Passer le capteur en mode mise à jour ?",
            isPresented: $showDfuConfirmation,
            titleVisibility: .visible
        ) {
            Button("Passer en mode DFU") {
                Task { await enterDfuMode() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le capteur cessera d'enregistrer et se déconnectera. Il revient en fonctionnement normal après la mise à jour, ou en le sortant de la sangle pour le redémarrer.")
        }
        .confirmationDialog(
            "Toutes les séances du capteur sont importées. Effacer sa mémoire ?",
            isPresented: $showEraseAfterImportPrompt,
            titleVisibility: .visible
        ) {
            Button("Effacer la mémoire", role: .destructive) {
                Task { await eraseMemory() }
            }
            Button("Garder", role: .cancel) {}
        } message: {
            Text("Le capteur n'affiche que quatre enregistrements : le vider après chaque sortie évite que les suivants deviennent invisibles.")
        }
    }

    /// How close the sensor is to the point where recordings stop being
    /// listed. Warning only once the listing is already full would be too
    /// late — by then the athlete has to go hunting for hidden entries — so
    /// the reminder comes one recording early.
    private enum MemoryPressure {
        case approaching
        case atCap
    }

    private var memoryPressure: MemoryPressure? {
        if hasUnlistedEntries || entries.count >= 4 { return .atCap }
        if entries.count >= 3 { return .approaching }
        return nil
    }

    @ViewBuilder
    private func memoryWarning(_ pressure: MemoryPressure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                pressure == .atCap ? "La liste du capteur est pleine" : "Trois séances sur le capteur",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(pressure == .atCap ? Color.red : Color.orange)

            Text(pressure == .atCap
                 ? "Le capteur n'en affiche que quatre. Les enregistrements suivants existent toujours, mais n'apparaissent plus ici : va les chercher avec « Récupérer les séances masquées », puis efface la mémoire."
                 : "À la quatrième, les suivantes n'apparaîtront plus dans cette liste. Télécharge celles qui manquent, puis efface la mémoire du capteur.")
            .font(.callout)

            // The confirmation this opens counts what has not been downloaded
            // from this screen and says so, so offering the shortcut here
            // cannot quietly erase a session that was never fetched.
            Button("Effacer la mémoire du capteur…") {
                showEraseConfirmation = true
            }
            .disabled(entries.isEmpty)
        }
        .padding(.vertical, 4)
    }

    /// Puts the sensor into firmware-update mode.
    ///
    /// `SystemMode` 12 is `FwUpdateMode` in the SDK's `system/mode.yaml`. It is
    /// needed because a Movesense running its application does **not** expose
    /// the Nordic DFU service — nRF Connect answers "this device does not
    /// support Nordic nor McuMgr DFU update mechanisms", which reads like the
    /// wrong hardware rather than the wrong mode. The switch itself is only
    /// reachable over GSP, so it has to happen here rather than in nRF Connect.
    private func toggleHeartRateProbe() async {
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else {
            errorMessage = String(localized: "Indisponible avec le capteur simulé.")
            return
        }
        if let reference = hrProbeReference {
            await movesense.unsubscribeHeartRate(reference: reference)
            hrProbeReference = nil
            return
        }
        hrProbeLines = []
        do {
            hrProbeReference = try await movesense.subscribeHeartRate { sample in
                Task { @MainActor in
                    for rr in sample.rrIntervalsMs {
                        // Shows the interval and the rate it implies beside the
                        // sensor's own averaged figure: the two disagreeing by
                        // more than a couple of bpm would mean the decode is
                        // wrong, and that is worth seeing while it streams.
                        let line = String(
                            format: "%4d ms · %.0f bpm   (moy. %.1f)",
                            rr, 60_000.0 / Double(max(rr, 1)), sample.bpm)
                        hrProbeLines.append(line)
                        if hrProbeLines.count > 10 { hrProbeLines.removeFirst() }
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enterDfuMode() async {
        isEnteringDfu = true
        defer { isEnteringDfu = false }
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else {
            errorMessage = String(localized: "Indisponible avec le capteur simulé.")
            return
        }
        do {
            try await movesense.enterFirmwareUpdateMode()
            // It drops the link on the way out, which is the expected ending
            // rather than a failure — say so, since a disconnection right
            // after a tap otherwise reads as one.
            importStatusMessage = String(localized: "Capteur en mode mise à jour. Il s'est déconnecté : envoie le paquet DFU depuis nRF Connect.")
            entries = []
            // The sensor is gone; leaving the screen showing it as connected is
            // what made this look like the switch had failed.
            await appEnvironment.sensorService.disconnect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recordings this run has actually downloaded and imported.
    ///
    /// Safety before erasing cannot be inferred from the stored sessions: the
    /// only shared key is the logbook id, which is a slot in the sensor's
    /// memory and restarts at 1 after an erase, so a fresh recording matches an
    /// old session and looks safe when it is not. The listing's start date
    /// can't rescue it either — before download it is only an estimate. So
    /// safety is *observed* rather than deduced, and an entry counts only once
    /// it has come across.
    private var notYetImportedCount: Int {
        entries.filter { !importedThisRun.contains($0.id) }.count
    }

    private var eraseConfirmationTitle: String {
        let missing = notYetImportedCount
        if missing > 0 {
            // Says "not downloaded here", not "not in the app": the app cannot
            // tell whether a recording it never fetched is already stored, and
            // claiming otherwise is what would get one erased.
            return String(localized: "\(entries.count) séance(s) sur le capteur, dont \(missing) que tu n'as pas téléchargée(s) depuis cet écran. Les effacer quand même ?")
        }
        return String(localized: "Effacer les \(entries.count) séance(s) du capteur ? Toutes ont été téléchargées à l'instant.")
    }

    /// Shown once, the first time a sensor is connected. Picking is the
    /// athlete's job because nothing in a BLE advertisement says whose sensor
    /// it is — signal strength included, since a sensor in a nearby bag can
    /// easily out-shout one on the body.
    private var sensorPicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discoveredSensors) { sensor in
                        Button {
                            showSensorPicker = false
                            Task { await connect(to: sensor, pairing: true) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sensor.name)
                                    if let rssi = sensor.rssi {
                                        Text("signal \(rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Capteurs à portée")
                } footer: {
                    Text("Choisis le tien : compare les derniers chiffres avec ceux inscrits sur ton capteur. L'app ne se connectera plus qu'à celui-là, et refusera d'importer une séance venue d'un autre. Tu pourras en changer dans Réglages.")
                }
            }
            .navigationTitle("Quel capteur est le tien ?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showSensorPicker = false }
                }
            }
        }
    }

    /// Remaining charge, shown beside the firmware.
    ///
    /// Worth its line: a coin cell in a sensor that starts recording on its
    /// own gives no sign it is dying. The failure it causes — a session that
    /// simply is not there — looks exactly like the strap having slipped, so
    /// the number has to be visible before the athlete goes to the water.
    @ViewBuilder
    private var batteryRow: some View {
        if case .connected = connectionState,
           let percent = (appEnvironment.sensorService as? MovesenseSensorService)?.batteryPercent {
            HStack {
                Label("Batterie", systemImage: batterySymbol(percent))
                    .foregroundStyle(percent <= 15 ? Color.red : percent <= 30 ? Color.orange : Color.secondary)
                Spacer()
                Text("\(percent) %")
                    .foregroundStyle(percent <= 15 ? Color.red : .secondary)
                    .monospacedDigit()
            }
            .font(.caption)

            if percent <= 30 {
                // Named as an errand rather than a status: the pile is a
                // CR2025 from any supermarket, and saying so is what turns a
                // warning into something done this week.
                Text(percent <= 15
                     ? "Remplace la pile (CR2025) avant la prochaine sortie."
                     : "Pense à prévoir une pile CR2025 de rechange.")
                    .font(.caption2)
                    .foregroundStyle(percent <= 15 ? Color.red : Color.orange)
            }
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<15: "battery.0percent"
        case ..<40: "battery.25percent"
        case ..<70: "battery.50percent"
        default: "battery.100percent"
        }
    }

    /// The firmware the sensor is running. Worth showing: whether a sensor
    /// carries the stock firmware or ours changes when recordings start and
    /// stop, and after a DFU there is otherwise no way to confirm the update
    /// took.
    @ViewBuilder
    private var firmwareRow: some View {
        if case .connected = connectionState,
           let name = (appEnvironment.sensorService as? MovesenseSensorService)?.connectedFirmwareName,
           !name.isEmpty {
            HStack {
                Text("Firmware").foregroundStyle(.secondary)
                Spacer()
                Text(firmwareLabel(name)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    /// What the firmware believes, and what it last decided.
    ///
    /// The journal is the part that matters: reading a live flag while
    /// connected cannot answer a question about a morning when nothing was
    /// connected — and `phoneConnected` is true by construction while this is
    /// on screen. The entries were filed as the decisions were taken.
    @ViewBuilder
    private var diagnosticsSection: some View {
        Section("Diagnostic capteur") {
            if let diagnostics {
                LabeledContent("Contact sangle", value: contactLabel(diagnostics.connector))
                LabeledContent("Mouvement", value: contactLabel(diagnostics.movement))
                LabeledContent("Enregistrement",
                               value: diagnostics.isLogging
                                   ? String(localized: "en cours")
                                   : String(localized: "arrêté"))
                if diagnostics.isArming || diagnostics.aliveTransitions > 0 || diagnostics.wildTransitions > 0 {
                    LabeledContent("Battements analysés",
                                   value: String(localized: "\(diagnostics.aliveTransitions) plausibles · \(diagnostics.wildTransitions) aberrants"))
                    LabeledContent("Dernier battement", value: lastBeatLabel(diagnostics))
                }
                if let blocking = blockingState(diagnostics) {
                    Label(blocking, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if diagnostics.logbookFull {
                    Text("Mémoire pleine : le capteur a cessé d'enregistrer.")
                        .font(.caption).foregroundStyle(.orange)
                }

                if diagnostics.journal.isEmpty {
                    Text("Aucune décision enregistrée depuis le démarrage du capteur.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics.journal.reversed()) { note in
                        HStack(alignment: .firstTextBaseline) {
                            Text(label(for: note.code)).font(.caption)
                            Spacer()
                            Text(age(note.secondsAgo))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }

            Button {
                Task { await readDiagnostics() }
            } label: {
                if isReadingDiagnostics {
                    ProgressView()
                } else {
                    Text(diagnostics == nil ? "Lire l'état du capteur" : "Relire")
                }
            }
            .disabled(isReadingDiagnostics)

            Text("Le journal remonte au dernier redémarrage du capteur, le plus récent en haut. Un téléphone connecté empêche le démarrage automatique, volontairement : c'est pourquoi c'est le journal qu'il faut lire, pas l'état courant.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Separates a pulse judged unconvincing from no pulse arriving at all —
    /// the journal says "pouls non trouvé" for both.
    private func lastBeatLabel(_ d: SensorDiagnostics) -> String {
        guard let seconds = d.secondsSinceLastBeat else {
            return String(localized: "aucun depuis le démarrage")
        }
        if d.lastHeartRate > 0 {
            return String(localized: "il y a \(seconds) s · \(d.lastHeartRate) bpm")
        }
        return String(localized: "il y a \(seconds) s")
    }

    /// The reason arming cannot happen right now, if there is one.
    private func blockingState(_ d: SensorDiagnostics) -> String? {
        if d.transitionPending { return String(localized: "Le capteur attend la fin d'un démarrage ou d'un arrêt.") }
        if d.externalStopHonoured { return String(localized: "Arrêt manuel respecté : pas de redémarrage automatique pour l'instant.") }
        if d.isPaused { return String(localized: "En pause entre deux tentatives de détection du pouls.") }
        return nil
    }

    private func label(for code: SensorDiagnostics.Code) -> String {
        switch code {
        case .strapOn:                String(localized: "Sangle en contact")
        case .strapOff:               String(localized: "Contact perdu")
        case .armingBegan:            String(localized: "Recherche du pouls lancée")
        case .pulseFound:             String(localized: "Pouls trouvé")
        case .armingTimedOut:         String(localized: "Pouls non trouvé, pause")
        case .blockedByPhone:         String(localized: "Refusé : téléphone connecté")
        case .blockedByExternalStop:  String(localized: "Refusé : arrêt manuel respecté")
        case .blockedByPause:         String(localized: "Refusé : en pause")
        case .blockedByBusy:          String(localized: "Refusé : démarrage ou arrêt en cours")
        case .recordingStarted:       String(localized: "Enregistrement démarré")
        case .recordingStopped:       String(localized: "Enregistrement arrêté")
        case .externalStop:           String(localized: "Arrêté par l'app")
        case .alreadyArming:          String(localized: "Recherche du pouls déjà en cours")
        }
    }

    /// Ages, not clock times: the sensor's clock resets to 2015 on every power
    /// loss, and "il y a 3 h" is what places a morning anyway.
    private func age(_ seconds: Int) -> String {
        if seconds >= 65_535 { return String(localized: "il y a plus de 18 h") }
        if seconds < 60 { return String(localized: "il y a \(seconds) s") }
        if seconds < 3600 { return String(localized: "il y a \(seconds / 60) min") }
        return String(localized: "il y a \(seconds / 3600) h \((seconds % 3600) / 60) min")
    }

    private func contactLabel(_ state: UInt8) -> String {
        switch state {
        case 0: String(localized: "non")
        case 1: String(localized: "oui")
        default: String(localized: "inconnu")
        }
    }

    private func readDiagnostics() async {
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else { return }
        isReadingDiagnostics = true
        defer { isReadingDiagnostics = false }
        do {
            diagnostics = try await movesense.readDiagnostics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var connectionRow: some View {
        HStack {
            Text(connectionLabel)
            Spacer()
            if isScanning {
                ProgressView()
            } else if case .disconnected = connectionState {
                Button("Rechercher") { Task { await scanAndConnect() } }
            } else if case .connected = connectionState {
                Button("Déconnecter") { Task { await appEnvironment.sensorService.disconnect() } }
            }
        }
    }

    private var connectionLabel: String {
        switch connectionState {
        case .disconnected: String(localized: "Déconnecté")
        case .connecting: String(localized: "Connexion...")
        case .connected(let sensor): sensor.name
        case .disconnecting: String(localized: "Déconnexion...")
        }
    }

    private func entryRow(_ entry: LogbookEntryInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.startDate.formatted(date: .abbreviated, time: .shortened))
                Text("\(Int(entry.duration / 60)) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = downloadProgress[entry.id] {
                ProgressView(value: progress).frame(width: 60)
            } else {
                Button("Télécharger") { Task { await download(entry) } }
            }
        }
    }

    private func observeConnection() async {
        for await state in appEnvironment.sensorService.connectionState {
            connectionState = state
            if case .connected = state {
                // Ask the sensor whether it is recording rather than trusting
                // our own start/stop history: it records on its own, so after
                // an app relaunch (or a session started from another phone)
                // the button would otherwise offer the wrong action.
                isLogging = (try? await appEnvironment.sensorService.isCurrentlyLogging()) ?? isLogging
                await refreshEntries()
            } else if case .disconnected = state {
                isLogging = false
            }
        }
    }

    /// Serial of the sensor currently connected, stamped onto whatever is
    /// imported from it. Empty for the simulated sensor, which is treated as
    /// unknown rather than rejected.
    private var connectedSerial: String {
        (appEnvironment.sensorService as? MovesenseSensorService)?.connectedSerialNumber ?? ""
    }

    /// Does the advertised sensor carry this serial? Before connecting, all
    /// that is known is the BLE name, which ends with the serial; the paired
    /// value is the serial itself, read from the hello response at pairing.
    private static func matches(_ sensor: DiscoveredSensor, _ serial: String) -> Bool {
        sensor.id == serial || sensor.name.hasSuffix(serial)
    }

    /// Gathers the sensors in range, stopping early once the paired one
    /// answers. Collecting rather than taking the first to reply is the whole
    /// point: in a clubhouse the first to reply is somebody else's.
    private func collectSensors(seconds: Double, stoppingAt paired: String?) async -> [DiscoveredSensor] {
        let stream = appEnvironment.sensorService.scan()
        var found: [String: DiscoveredSensor] = [:]

        let collector = Task { @MainActor in
            for await sensor in stream {
                found[sensor.id] = sensor
                if let paired, Self.matches(sensor, paired) { break }
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            collector.cancel()
        }
        await collector.value
        timeout.cancel()
        appEnvironment.sensorService.stopScan()

        return found.values.sorted { ($0.rssi ?? -200) > ($1.rssi ?? -200) }
    }

    private func scanAndConnect() async {
        isScanning = true
        defer { isScanning = false }
        errorMessage = nil

        let paired = appEnvironment.pairedSensorSerial
        // Unpaired, the wait runs its full course so every sensor in range is
        // offered; paired, it ends the moment the right one answers.
        let found = await collectSensors(seconds: paired == nil ? 6 : 15, stoppingAt: paired)

        guard !found.isEmpty else {
            var message = String(localized: "Aucun capteur trouvé. Vérifie que le Bluetooth est activé, que MoveLoad y a accès (Réglages > MoveLoad > Bluetooth), et que le capteur est porté et à proximité.")
            if let movesense = appEnvironment.sensorService as? MovesenseSensorService {
                message += "\n(\(movesense.diagnosticStateDescription))"
                message += "\n\n" + (await movesense.debugScanBroad())
            }
            errorMessage = message
            return
        }

        guard let paired else {
            // First time: the athlete says which sensor is theirs. Nothing is
            // connected automatically, because there is no way to guess.
            discoveredSensors = found
            showSensorPicker = true
            return
        }

        guard let mine = found.first(where: { Self.matches($0, paired) }) else {
            // Say what did answer: it is how the athlete works out their
            // sensor is flat, not worn, or left at home.
            let others = found.map(\.name).joined(separator: ", ")
            errorMessage = String(localized: "Ton capteur (\(paired)) n'a pas répondu. \(found.count) autre(s) capteur(s) à portée : \(others). Vérifie que le tien est porté, sangle en place, et que sa pile n'est pas vide.")
            return
        }

        await connect(to: mine, pairing: false)
    }

    private func connect(to sensor: DiscoveredSensor, pairing: Bool) async {
        do {
            try await appEnvironment.sensorService.connect(to: sensor)
            if pairing {
                // Store the serial the sensor reports rather than the name it
                // advertises: the hello response is the authoritative one, and
                // it is what every later comparison is made against.
                if let serial = (appEnvironment.sensorService as? MovesenseSensorService)?.connectedSerialNumber,
                   !serial.isEmpty {
                    appEnvironment.pairedSensorSerial = serial
                } else {
                    appEnvironment.pairedSensorSerial = sensor.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleLogging() async {
        isTogglingLogging = true
        defer { isTogglingLogging = false }
        do {
            if isLogging {
                try await appEnvironment.sensorService.stopLogging()
                isLogging = false
                // Warn straight away if the recording left nothing behind —
                // at the water's edge the session can still be redone, hours
                // later it is simply lost.
                if let movesense = appEnvironment.sensorService as? MovesenseSensorService,
                   movesense.lastStopProducedNewEntry == false {
                    errorMessage = String(localized: "Attention : l'arrêt n'a produit aucun nouvel enregistrement dans le capteur. La séance n'a probablement pas été sauvegardée. Vérifie que le capteur est resté en contact avec la sangle pendant toute la séance.")
                }
                // stopLogging reboots the sensor (per the official tool's
                // flow), which disconnects it — don't refresh entries here,
                // the connection will drop and the user reconnects to fetch.
            } else {
                // A sensor that has halted on a full logbook would accept the
                // start and record nothing, which is only discovered afterwards.
                if let full = try? await appEnvironment.sensorService.isStorageFull(), full == true {
                    errorMessage = String(localized: "La mémoire du capteur est pleine : il ne peut plus enregistrer. Télécharge tes séances puis utilise « Effacer toute la mémoire du capteur ».")
                    return
                }
                try await appEnvironment.sensorService.startLogging(config: LoggingConfig())
                isLogging = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Walks past the end of what the sensor will list, downloading each
    /// recording until one isn't there. Fetching *is* the existence test, so
    /// nothing is downloaded twice.
    private func recoverHiddenSessions() async {
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService else {
            recoveryStatus = String(localized: "Indisponible avec le capteur simulé.")
            return
        }
        isRecoveringHidden = true
        defer { isRecoveringHidden = false }
        errorMessage = nil

        let highestListed = entries.compactMap { UInt32($0.id) }.max() ?? 0
        var nextID = highestListed + 1
        var recovered = 0
        var skipped = 0

        do {
            // Bounded so a sensor that answered forever couldn't trap the UI.
            while nextID <= highestListed + 16 {
                recoveryStatus = String(localized: "Recherche de l'enregistrement \(nextID)…")
                guard let raw = try await movesense.downloadEntry(id: nextID, progress: { _ in }) else {
                    break
                }
                // Deliberately downloaded before deciding it's a duplicate:
                // the logbook id restarts at 1 after an erase, so skipping on
                // the id alone would silently discard genuinely new
                // recordings. Costs bandwidth on a repeat run; losing a
                // session costs more.
                let outcome = try appEnvironment.importSession(
                    raw: raw,
                    logbookEntryID: String(nextID),
                    sensorSerial: connectedSerial
                )
                if outcome.wasAlreadyImported { skipped += 1 } else { recovered += 1 }
                nextID += 1
            }

            switch (recovered, skipped) {
            case (0, 0):
                recoveryStatus = String(localized: "Aucun enregistrement masqué au-delà du \(highestListed).")
            case (0, _):
                recoveryStatus = String(localized: "Rien de nouveau : \(skipped) séance(s) masquée(s) déjà importée(s).")
            default:
                recoveryStatus = String(localized: "\(recovered) séance(s) récupérée(s) et importée(s).")
            }
            await refreshEntries()
        } catch {
            errorMessage = error.localizedDescription
            recoveryStatus = recovered > 0 ? String(localized: "\(recovered) séance(s) récupérée(s) avant l'erreur.") : nil
        }
    }

    private func eraseMemory() async {
        isErasingMemory = true
        defer { isErasingMemory = false }
        do {
            try await appEnvironment.sensorService.eraseAllEntries()
            await refreshEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshEntries() async {
        isRefreshingEntries = true
        defer { isRefreshingEntries = false }
        do {
            entries = try await appEnvironment.sensorService.listLogbookEntries()
            if let movesense = appEnvironment.sensorService as? MovesenseSensorService {
                hasUnlistedEntries = movesense.hasUnlistedEntries
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Debit of the last logbook download, over the air.
    ///
    /// Here because the cost of the custom firmware's pinned MTU cannot be
    /// read from the headers — it has to be timed on the same recording before
    /// flashing and after. A stopwatch impression is not comparable; this is.
    /// "MoveLoad Auto 1.1.0" rather than just the name. Two images that behave
    /// differently and report the same version cannot be told apart once
    /// flashed, which is exactly the position this got into.
    private func firmwareLabel(_ name: String) -> String {
        let version = (appEnvironment.sensorService as? MovesenseSensorService)?.connectedFirmwareVersion ?? ""
        return version.isEmpty ? name : "\(name) \(version)"
    }

    private var lastTransferLine: String? {
        guard let movesense = appEnvironment.sensorService as? MovesenseSensorService,
              let last = movesense.lastTransfer, last.seconds > 0
        else { return nil }

        let size = ByteCountFormatter.string(fromByteCount: Int64(last.bytes), countStyle: .file)
        let rate = ByteCountFormatter.string(fromByteCount: Int64(last.bytesPerSecond.rounded()), countStyle: .file)
        let seconds = Int(last.seconds.rounded())
        let duration = seconds >= 60
            ? String(localized: "\(seconds / 60) min \(String(format: "%02d", seconds % 60)) s")
            : String(localized: "\(seconds) s")
        return String(localized: "Dernier téléchargement : \(size) en \(duration) — \(rate)/s")
    }

    private func download(_ entry: LogbookEntryInfo) async {
        do {
            let data = try await appEnvironment.sensorService.downloadEntry(entry) { progress in
                Task { @MainActor in downloadProgress[entry.id] = progress }
            }
            _ = try appEnvironment.importSession(
                raw: data,
                logbookEntryID: entry.id,
                sensorSerial: connectedSerial
            )
            importedThisRun.insert(entry.id)
            downloadProgress[entry.id] = nil
            await refreshEntries()
            // Nothing left on the sensor that isn't safely imported, so offer
            // to clear it. Per-recording deletion doesn't exist in this
            // protocol — only the whole logbook — which is why this waits
            // until everything is in rather than cleaning up as it goes.
            if notYetImportedCount == 0 && !entries.isEmpty {
                showEraseAfterImportPrompt = true
            }
        } catch {
            // 409 is the sensor refusing to read a logbook entry it is still
            // writing to. That is correct behaviour and a normal thing to walk
            // into — the recording starts by itself, so the entry at the top of
            // the list is often the one in progress. "Commande GSP fetchLog a
            // échoué (code 409)" said nothing about what to do.
            if case MovesenseGSPClient.GSPError.commandFailed(_, 409) = error {
                errorMessage = String(localized: "Cette séance est encore en cours d'enregistrement : le capteur ne peut pas la relire tant qu'elle est ouverte. Arrête l'enregistrement, puis rafraîchis la liste.")
            } else {
                errorMessage = error.localizedDescription
            }
            downloadProgress[entry.id] = nil
        }
    }

    private func handleShowcaseImport(_ result: Result<[URL], Error>) async {
        isImportInProgress = true
        importStatusMessage = nil
        errorMessage = nil
        defer { isImportInProgress = false }

        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }

            var accelFile: (filename: String, data: Data)?
            var hrData: Data?

            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    throw SensorError.transferFailed(String(localized: "Accès refusé à \(url.lastPathComponent)."))
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let data = try Data(contentsOf: url)
                if MovesenseShowcaseJSON.looksLikeAcceleration(data) {
                    accelFile = (url.lastPathComponent, data)
                } else {
                    hrData = data
                }
            }

            guard let accelFile else {
                throw SensorError.transferFailed(String(localized: "Aucun fichier acc_stream.json reconnu parmi les fichiers sélectionnés."))
            }

            let (axes, sampleRateHz) = try MovesenseShowcaseJSON.parseAcceleration(accelFile.data)
            let hrSamples = try hrData.map { try MovesenseShowcaseJSON.parseHeartRate($0) } ?? []
            let startDate = MovesenseShowcaseJSON.startDate(fromFilename: accelFile.filename)

            let raw = RawSessionData(
                startDate: startDate,
                accelSampleRateHz: sampleRateHz,
                axes: axes,
                hrSamples: hrSamples
            )
            _ = try appEnvironment.importSession(raw: raw, logbookEntryID: "showcase-\(UUID().uuidString)")
            importStatusMessage = String(localized: "Séance importée : \(startDate.formatted(date: .abbreviated, time: .shortened)), \(Int(raw.duration / 60)) min.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
