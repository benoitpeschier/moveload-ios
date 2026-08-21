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

    var body: some View {
        List {
            Section("Connexion") {
                connectionRow
                firmwareRow
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
                }

                Section {
                    if isRecoveringHidden {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView()
                            Text(recoveryStatus ?? "Recherche…")
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
            return "\(entries.count) séance(s) sur le capteur, dont \(missing) que tu n'as pas téléchargée(s) depuis cet écran. Les effacer quand même ?"
        }
        return "Effacer les \(entries.count) séance(s) du capteur ? Toutes ont été téléchargées à l'instant."
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
                Text(name).foregroundStyle(.secondary)
            }
            .font(.caption)
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
        case .disconnected: "Déconnecté"
        case .connecting: "Connexion..."
        case .connected(let sensor): sensor.name
        case .disconnecting: "Déconnexion..."
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
            var message = "Aucun capteur trouvé. Vérifie que le Bluetooth est activé, que MoveLoad y a accès (Réglages > MoveLoad > Bluetooth), et que le capteur est porté et à proximité."
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
            errorMessage = "Ton capteur (\(paired)) n'a pas répondu. \(found.count) autre(s) capteur(s) à portée : \(others). Vérifie que le tien est porté, sangle en place, et que sa pile n'est pas vide."
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
                    errorMessage = "Attention : l'arrêt n'a produit aucun nouvel enregistrement dans le capteur. La séance n'a probablement pas été sauvegardée. Vérifie que le capteur est resté en contact avec la sangle pendant toute la séance."
                }
                // stopLogging reboots the sensor (per the official tool's
                // flow), which disconnects it — don't refresh entries here,
                // the connection will drop and the user reconnects to fetch.
            } else {
                // A sensor that has halted on a full logbook would accept the
                // start and record nothing, which is only discovered afterwards.
                if let full = try? await appEnvironment.sensorService.isStorageFull(), full == true {
                    errorMessage = "La mémoire du capteur est pleine : il ne peut plus enregistrer. Télécharge tes séances puis utilise « Effacer toute la mémoire du capteur »."
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
            recoveryStatus = "Indisponible avec le capteur simulé."
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
                recoveryStatus = "Recherche de l'enregistrement \(nextID)…"
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
                recoveryStatus = "Aucun enregistrement masqué au-delà du \(highestListed)."
            case (0, _):
                recoveryStatus = "Rien de nouveau : \(skipped) séance(s) masquée(s) déjà importée(s)."
            default:
                recoveryStatus = "\(recovered) séance(s) récupérée(s) et importée(s)."
            }
            await refreshEntries()
        } catch {
            errorMessage = error.localizedDescription
            recoveryStatus = recovered > 0 ? "\(recovered) séance(s) récupérée(s) avant l'erreur." : nil
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
            errorMessage = error.localizedDescription
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
                    throw SensorError.transferFailed("Accès refusé à \(url.lastPathComponent).")
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
                throw SensorError.transferFailed("Aucun fichier acc_stream.json reconnu parmi les fichiers sélectionnés.")
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
            importStatusMessage = "Séance importée : \(startDate.formatted(date: .abbreviated, time: .shortened)), \(Int(raw.duration / 60)) min."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
