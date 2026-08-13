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

    private var connectionContinuation: AsyncStream<SensorConnectionState>.Continuation?
    private var state: SensorConnectionState = .disconnected {
        didSet { connectionContinuation?.yield(state) }
    }

    private var connectedSerial: String?
    private var connectedSensor: DiscoveredSensor?

    public private(set) lazy var connectionState: AsyncStream<SensorConnectionState> = AsyncStream { continuation in
        self.connectionContinuation = continuation
        continuation.yield(self.state)
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
        try await gsp.putDataLoggerState(3) // LOGGING
    }

    public func stopLogging() async throws {
        try await gsp.putDataLoggerState(2) // READY
        // Matches the official tool's stop flow: reboot the sensor
        // (system mode 5) so the next start begins a fresh log. This
        // disconnects the sensor — `onDisconnect` updates `state`.
        try? await gsp.putSystemMode(5)
    }

    public func listLogbookEntries() async throws -> [LogbookEntryInfo] {
        let entries = try await gsp.getLogbookEntries()
        return entries.map { entry in
            // `lastModified` is a Unix epoch timestamp in seconds; fall back
            // to "now" if it looks obviously invalid (0 or absurd).
            let date = entry.lastModified > 0
                ? Date(timeIntervalSince1970: TimeInterval(entry.lastModified))
                : Date()
            // No accurate duration without decoding — rough estimate from
            // size assuming ~52Hz accel (12 bytes/sample after SBEM framing
            // overhead, generously rounded) purely so the list isn't empty;
            // the real value comes from the decoded session at import time.
            let estimatedDuration = TimeInterval(entry.size) / 900.0
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

    public func deleteEntry(_ entry: LogbookEntryInfo) async throws {
        // GSP only exposes a whole-logbook erase (CLEAR_LOGBOOK), not a
        // per-entry delete — silently wiping every other stored session
        // just because one was downloaded would be a real data-loss risk,
        // so this is deliberately a no-op. Use eraseAllEntries() for the
        // explicit, user-confirmed whole-logbook clear.
    }

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
