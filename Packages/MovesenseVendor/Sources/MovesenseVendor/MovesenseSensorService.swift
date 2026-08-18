import Foundation
import CoreBluetooth
import MoveLoadCore
import SensorKit

/// Real `SensorService` implementation on top of the GSP (GATT SensorData
/// Protocol) client — see `MovesenseGSPClient`. Originally this used
/// `MDSWrapper` (MDS/Whiteboard-over-BLE) throughout, but `doPut` against
/// `Mem/DataLogger` fails unconditionally on this device's stock firmware
/// regardless of path/payload format (extensively tested 2026-08-11).
/// Movesense's own official `python-datalogger-tool` — confirmed working
/// against this exact sensor (2026-08-13) — uses a completely different,
/// lower-level GATT protocol instead of MDS for this; `MovesenseGSPClient`
/// is a Swift port of that protocol. Discovery/scanning here is unchanged
/// from before (plain CoreBluetooth, filtering on the advertised `FDF3`
/// service UUID) — only the connection and command layer changed.
public final class MovesenseSensorService: NSObject, SensorService {
    private let gsp = MovesenseGSPClient()
    private var centralManager: CBCentralManager?
    private var wantsScanning = false
    private var scanContinuation: AsyncStream<DiscoveredSensor>.Continuation?

    /// One continuation per live observer. This used to be a single `lazy var`
    /// stream, which meant only the first consumer ever received anything:
    /// SwiftUI restarts a view's `.task` (switching tabs, for one), and the
    /// second iteration of an already-consumed AsyncStream silently receives
    /// nothing — leaving the screen stuck on a stale state with buttons that
    /// looked broken.
    private var connectionContinuations: [UUID: AsyncStream<SensorConnectionState>.Continuation] = [:]
    private let continuationsLock = NSLock()

    private var state: SensorConnectionState = .disconnected {
        didSet { broadcast(state) }
    }

    private var connectedSerial: String?
    private var connectedSensor: DiscoveredSensor?

    public var connectionState: AsyncStream<SensorConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuationsLock.lock()
            connectionContinuations[id] = continuation
            let current = state
            continuationsLock.unlock()

            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.continuationsLock.lock()
                self.connectionContinuations[id] = nil
                self.continuationsLock.unlock()
            }
        }
    }

    private func broadcast(_ newState: SensorConnectionState) {
        continuationsLock.lock()
        let observers = connectionContinuations.values
        continuationsLock.unlock()
        for continuation in observers { continuation.yield(newState) }
    }

    public override init() {
        super.init()
        Task { await gsp.setOnDisconnect { [weak self] in self?.handleUnexpectedDisconnect() } }
    }

    private func handleUnexpectedDisconnect() {
        DispatchQueue.main.async {
            self.connectedSerial = nil
            self.connectedSensor = nil
            self.state = .disconnected
        }
    }

    /// Surfaces the actual CoreBluetooth authorization/power state for
    /// display in error messages — turns "aucun capteur trouvé" from a
    /// guessing game into an actionable diagnostic (permission denied vs.
    /// Bluetooth off vs. genuinely nothing advertising nearby).
    public var diagnosticStateDescription: String {
        let authorization: String
        switch CBCentralManager.authorization {
        case .allowedAlways: authorization = "autorisé"
        case .denied: authorization = "refusé"
        case .restricted: authorization = "restreint"
        case .notDetermined: authorization = "non demandé"
        @unknown default: authorization = "inconnu"
        }
        let managerState: String
        switch centralManager?.state {
        case .poweredOn: managerState = "activé"
        case .poweredOff: managerState = "désactivé"
        case .unauthorized: managerState = "non autorisé"
        case .unsupported: managerState = "non supporté sur cet appareil"
        case .resetting: managerState = "réinitialisation en cours"
        case .unknown, .none: managerState = "indéterminé"
        @unknown default: managerState = "inconnu"
        }
        return "Bluetooth : \(managerState) · Autorisation MoveLoad : \(authorization)"
    }

    private var debugDiscoveries: [String: (name: String?, uuids: [String])] = [:]

    /// Debug-only: scans with no service filter at all, so we can tell
    /// whether the Movesense sensor is advertising nearby under a different
    /// service UUID than expected, or isn't advertising at all (already
    /// connected elsewhere, asleep, out of range, off).
    public func debugScanBroad(duration: TimeInterval = 8) async -> String {
        guard let manager = centralManager, manager.state == .poweredOn else {
            return "Scan large impossible (\(diagnosticStateDescription))"
        }
        debugDiscoveries.removeAll()
        manager.scanForPeripherals(withServices: nil, options: nil)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        manager.stopScan()
        startScanningIfPossible()

        if debugDiscoveries.isEmpty {
            return "Scan large (\(Int(duration))s) : aucun périphérique BLE détecté à proximité."
        }
        let lines = debugDiscoveries.values.map { entry -> String in
            let name = entry.name ?? "(sans nom)"
            let uuids = entry.uuids.isEmpty ? "aucun UUID de service annoncé" : entry.uuids.joined(separator: ", ")
            return "• \(name) — \(uuids)"
        }
        return "Scan large (\(Int(duration))s), \(debugDiscoveries.count) périphérique(s) :\n" + lines.joined(separator: "\n")
    }

    // MARK: - SensorConnectivityService

    public func scan() -> AsyncStream<DiscoveredSensor> {
        AsyncStream { continuation in
            self.scanContinuation = continuation
            self.wantsScanning = true
            if self.centralManager == nil {
                self.centralManager = CBCentralManager(delegate: self, queue: nil)
            } else {
                self.startScanningIfPossible()
            }
        }
    }

    public func stopScan() {
        wantsScanning = false
        centralManager?.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    public func connect(to sensor: DiscoveredSensor) async throws {
        state = .connecting
        do {
            // `MovesenseGSPClient` owns its own `CBCentralManager`, separate
            // from this class's scanning one — a `CBPeripheral` discovered
            // by one manager can't be connected via another, so we hand off
            // the sensor's *name* and let the GSP client do its own fresh
            // scan+connect rather than passing the `CBPeripheral` object
            // discovered above.
            try await gsp.connect(serialSuffix: sensor.name)
            let hello = try await gsp.hello()
            let serial = hello.serialNumber.isEmpty ? sensor.id : hello.serialNumber
            connectedSerial = serial
            let resolvedSensor = DiscoveredSensor(id: serial, name: serial, rssi: sensor.rssi)
            connectedSensor = resolvedSensor
            state = .connected(resolvedSensor)
        } catch {
            state = .disconnected
            throw error
        }
    }

    public func disconnect() async {
        state = .disconnecting
        await gsp.disconnect()
        connectedSerial = nil
        connectedSensor = nil
        state = .disconnected
    }

    /// Verified against a real Movesense Flash (broad unfiltered scan, 2026-08-11):
    /// the advertisement packet carries the short 16-bit service UUID `FDF3`
    /// (plus the standard `180D` Heart Rate Service), not the 128-bit GSP
    /// service UUID — that longer UUID is only exposed in the GATT service
    /// table after connecting, not in the ~31-byte advertisement payload.
    private static let advertisedServiceUUID = CBUUID(string: "FDF3")

    private func startScanningIfPossible() {
        guard wantsScanning, let manager = centralManager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: [Self.advertisedServiceUUID], options: nil)
    }

    // MARK: - SensorLogbookService

    /// 52 Hz matches `LoggingConfig`'s own default accelerometer rate — fine
    /// enough to resolve individual paddle strokes.
    private static let accelerometerPath = "/Meas/Acc/52"
    private static let heartRatePath = "/Meas/HR"

    public func startLogging(config: LoggingConfig) async throws {
        try await gsp.putDataLoggerConfig(paths: [Self.accelerometerPath, Self.heartRatePath])
        try await gsp.putDataLoggerState(Self.loggingStateValue)
    }

    /// DataLogger states, from the protocol reference: 2 = READY, 3 = LOGGING.
    private static let loggingStateValue: UInt8 = 3

    public func isCurrentlyLogging() async throws -> Bool {
        try await gsp.getDataLoggerState() == Self.loggingStateValue
    }

    /// True when the sensor holds recordings its listing refuses to show —
    /// reach them with `downloadEntry(id:progress:)`.
    public private(set) var hasUnlistedEntries = false

    public func isStorageFull() async throws -> Bool? {
        try await gsp.isLogbookFull()
    }

    public func stopLogging() async throws {
        // Count what's stored before the reboot, so the caller can tell
        // whether this recording actually produced an entry. Setting the
        // state to READY is what flushes the log to flash, so a recording
        // cut short by a power loss (the sensor is powered by strap contact)
        // can leave nothing behind at all — worth catching at the water's
        // edge rather than hours later.
        let entriesBefore = (try? await gsp.getLogbookEntries())?.count

        try await gsp.putDataLoggerState(2) // READY

        var newEntryConfirmed: Bool?
        if let entriesBefore, let after = try? await gsp.getLogbookEntries() {
            newEntryConfirmed = after.count > entriesBefore
        }
        lastStopProducedNewEntry = newEntryConfirmed

        // Matches the official tool's stop flow: reboot the sensor
        // (system mode 5) so the next start begins a fresh log. This
        // disconnects the sensor — `onDisconnect` updates `state`.
        try? await gsp.putSystemMode(5)
    }

    /// Set by `stopLogging`: true when a new logbook entry appeared, false
    /// when none did, nil when it couldn't be checked. Read straight after
    /// stopping.
    public private(set) var lastStopProducedNewEntry: Bool?

    public func listLogbookEntries() async throws -> [LogbookEntryInfo] {
        let entries = try await gsp.getLogbookEntries()
        hasUnlistedEntries = await gsp.moreEntriesExistBeyondListing
        return entries.map { entry in
            // No accurate duration without decoding: 730 bytes/s is what a
            // real accel+HR recording measured (2026-08-16), close enough to
            // label the list. The decoded session carries the true value.
            let estimatedDuration = TimeInterval(entry.size) / 730.0
            // `lastModified` is when recording *stopped*, not when it began
            // (verified against a real recording), so showing it as the start
            // date would put every entry a full session length late. Backing
            // the estimated duration off it is still approximate, but it is
            // wrong by the estimate's error rather than by the whole session.
            // The exact start comes out of the file itself once downloaded —
            // see MovesenseSBEMDecoder.
            let end = entry.lastModified > 0
                ? Date(timeIntervalSince1970: TimeInterval(entry.lastModified))
                : Date()
            let date = end.addingTimeInterval(-estimatedDuration)
            return LogbookEntryInfo(id: "\(entry.id)", startDate: date, duration: estimatedDuration, sizeBytes: Int(entry.size))
        }
    }

    public func downloadEntry(_ entry: LogbookEntryInfo, progress: @escaping (Double) -> Void) async throws -> RawSessionData {
        guard let logId = UInt32(entry.id) else {
            throw SensorError.transferFailed("Identifiant de log invalide : \(entry.id)")
        }
        let totalSize = max(entry.sizeBytes ?? 1, 1)
        let sbemData = try await gsp.fetchLog(id: logId) { bytesReceived in
            DispatchQueue.main.async { progress(min(0.95, Double(bytesReceived) / Double(totalSize))) }
        }
        let data = try MovesenseSBEMDecoder.decode(sbemData, startDate: entry.startDate)
        progress(1.0)
        return data
    }

    /// Downloads a recording the listing cannot show, returning nil once no
    /// log exists at that id. The sensor lists at most four entries and offers
    /// no reachable way to page past them, so recordings beyond the fourth are
    /// otherwise invisible — a real session went missing that way. The dates
    /// come out of the file itself, so the absent listing metadata costs
    /// nothing.
    public func downloadEntry(id: UInt32, progress: @escaping (Double) -> Void) async throws -> RawSessionData? {
        var lastBytes = 0
        guard let sbem = try await gsp.fetchLogIfPresent(id: id, progress: { bytes in
            lastBytes = bytes
            // Size is unknown ahead of time here, so report a slow creep
            // rather than a fake percentage.
            DispatchQueue.main.async { progress(min(0.95, Double(bytes) / 5_000_000)) }
        }) else { return nil }
        _ = lastBytes
        let data = try MovesenseSBEMDecoder.decode(sbem, startDate: Date())
        progress(1.0)
        return data
    }

    /// Clears the sensor's whole logbook. GSP offers CLEAR_LOGBOOK and nothing
    /// finer, so this is all-or-nothing by nature — callers confirm with the
    /// athlete first.
    public func eraseAllEntries() async throws {
        try await gsp.eraseMemory()
    }
}

extension MovesenseSensorService: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanningIfPossible()
        case .unauthorized, .poweredOff, .unsupported:
            // Bluetooth unusable for a reason the user has to fix themselves
            // (permission, powered off, unsupported hardware) — end the scan
            // stream so callers aren't left waiting on a source that will
            // never yield anything.
            wantsScanning = false
            scanContinuation?.finish()
            scanContinuation = nil
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        debugDiscoveries[peripheral.identifier.uuidString] = (peripheral.name, uuids)

        let sensor = DiscoveredSensor(id: peripheral.identifier.uuidString, name: peripheral.name ?? "Movesense", rssi: RSSI.intValue)
        scanContinuation?.yield(sensor)
    }
}
