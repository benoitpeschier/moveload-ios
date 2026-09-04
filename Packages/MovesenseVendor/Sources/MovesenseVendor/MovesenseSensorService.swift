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

    /// Remaining charge of the connected sensor, 0–100 %, or nil when it has
    /// not been read yet or the sensor refused to measure.
    ///
    /// A coin cell in a sensor that now records on its own is invisible until
    /// a session goes missing, so it is read once per connection rather than
    /// waited for.
    public private(set) var batteryPercent: Int?

    public func refreshBatteryLevel() async {
        batteryPercent = try? await gsp.getBatteryPercent()
    }

    /// Serial of the sensor currently connected, from its hello response.
    /// Stamped onto every session imported from it, so a recording can always
    /// be traced back to the hardware it came off.
    public var connectedSerialNumber: String? { connectedSerial }

    /// The firmware application the connected sensor is running, from its
    /// hello response. Read to tell the stock firmware from ours, and shown
    /// in the sensor screen so a flash can be confirmed at a glance.
    public private(set) var connectedFirmwareName: String?
    /// Shown beside the name because two images that behave differently and
    /// report the same version cannot be told apart once flashed — which is
    /// exactly the position this got into.
    public private(set) var connectedFirmwareVersion: String?

    /// Our own firmware brackets sessions itself, from strap contact, and
    /// keeps the state that decides it in RAM.
    private var sensorManagesItsOwnSessions: Bool {
        connectedFirmwareName == Self.autoFirmwareName
    }

    /// Must match `APPINFO_NAME` in Firmware/moveload_auto_app/App.cpp.
    private static let autoFirmwareName = "MoveLoad Auto"

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
            self.connectedFirmwareName = nil
            self.connectedFirmwareVersion = nil
            self.batteryPercent = nil
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
        case .allowedAlways: authorization = String(localized: "autorisé", bundle: .module)
        case .denied: authorization = String(localized: "refusé", bundle: .module)
        case .restricted: authorization = String(localized: "restreint", bundle: .module)
        case .notDetermined: authorization = String(localized: "non demandé", bundle: .module)
        @unknown default: authorization = String(localized: "inconnu", bundle: .module)
        }
        let managerState: String
        switch centralManager?.state {
        case .poweredOn: managerState = String(localized: "activé", bundle: .module)
        case .poweredOff: managerState = String(localized: "désactivé", bundle: .module)
        case .unauthorized: managerState = String(localized: "non autorisé", bundle: .module)
        case .unsupported: managerState = String(localized: "non supporté sur cet appareil", bundle: .module)
        case .resetting: managerState = String(localized: "réinitialisation en cours", bundle: .module)
        case .unknown, .none: managerState = String(localized: "indéterminé", bundle: .module)
        @unknown default: managerState = String(localized: "inconnu", bundle: .module)
        }
        return String(localized: "Bluetooth : \(managerState) · Autorisation MoveLoad : \(authorization)", bundle: .module)
    }

    private var debugDiscoveries: [String: (name: String?, uuids: [String])] = [:]

    /// Debug-only: scans with no service filter at all, so we can tell
    /// whether the Movesense sensor is advertising nearby under a different
    /// service UUID than expected, or isn't advertising at all (already
    /// connected elsewhere, asleep, out of range, off).
    public func debugScanBroad(duration: TimeInterval = 8) async -> String {
        guard let manager = centralManager, manager.state == .poweredOn else {
            return String(localized: "Scan large impossible (\(diagnosticStateDescription))", bundle: .module)
        }
        debugDiscoveries.removeAll()
        manager.scanForPeripherals(withServices: nil, options: nil)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        manager.stopScan()
        startScanningIfPossible()

        if debugDiscoveries.isEmpty {
            return String(localized: "Scan large (\(Int(duration))s) : aucun périphérique BLE détecté à proximité.", bundle: .module)
        }
        let lines = debugDiscoveries.values.map { entry -> String in
            let name = entry.name ?? String(localized: "(sans nom)", bundle: .module)
            let uuids = entry.uuids.isEmpty ? String(localized: "aucun UUID de service annoncé", bundle: .module) : entry.uuids.joined(separator: ", ")
            return "• " + name + " — " + uuids
        }
        return String(localized: "Scan large (\(Int(duration))s), \(debugDiscoveries.count) périphérique(s) :\n", bundle: .module) + lines.joined(separator: "\n")
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
            connectedFirmwareName = hello.appName
            connectedFirmwareVersion = hello.appVersion
            batteryPercent = try? await gsp.getBatteryPercent()
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
        connectedFirmwareName = nil
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
        //
        // Except on our own firmware, where the reboot would undo the stop
        // it follows. That firmware decides on its own when to record, from
        // strap contact and a detected pulse, and it holds "the app stopped
        // this, leave it alone" in RAM. A reboot loses that, and the sensor
        // comes back up still worn, still beating, and starts recording
        // again. It needs no reboot to begin a fresh log either: the next
        // recording starts when the strap comes off and goes back on.
        if !sensorManagesItsOwnSessions {
            try? await gsp.putSystemMode(5)
        }
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

    /// What the last logbook download actually cost over the air.
    ///
    /// The custom firmware compiles `MOVESENSE_BLE_CONFIG_2PERIPHERALS`, which
    /// pins the MTU at 23 — the BLE minimum, 20 bytes of payload per packet.
    /// The stock default is inside the prebuilt core library and cannot be read
    /// from the headers, so the cost of that choice **can only be measured**:
    /// time the same download before flashing and after. Logbook entries run to
    /// tens of megabytes, so a large penalty would be disqualifying.
    public struct TransferStats: Sendable {
        public let bytes: Int
        /// Wire time only. Decoding is deliberately excluded — it runs on the
        /// phone and has nothing to do with the link.
        public let seconds: TimeInterval
        public var bytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    }

    public private(set) var lastTransfer: TransferStats?

    /// Switches the sensor into firmware-update mode, where it exposes the
    /// Nordic DFU service. `SystemMode` 12 is `FwUpdateMode` in the SDK's
    /// `system/mode.yaml`; running the application it offers no DFU service at
    /// all, so nRF Connect reports the device as unsupported rather than as
    /// being in the wrong mode.
    ///
    /// The sensor drops the connection on its way into the bootloader, so the
    /// write is expected to be the last thing this link carries.
    /// Subscribes to the live heart-rate stream, decoded.
    ///
    /// This is what the HRV test reads: `rrIntervalsMs` is the measurement,
    /// `bpm` is the sensor's own smoothed figure and is only good for showing a
    /// number while the test runs. Returns the reference to close it with.
    public func subscribeHeartRate(
        onSample: @escaping @Sendable (HeartRateStreamSample) -> Void
    ) async throws -> UInt8 {
        try await gsp.subscribe(path: "/Meas/HR") { payload in
            if let sample = HeartRateStreamSample(payload: payload) { onSample(sample) }
        }
    }

    public func unsubscribeHeartRate(reference: UInt8) async {
        await gsp.unsubscribe(reference: reference)
    }

    public func enterFirmwareUpdateMode() async throws {
        // Deliberately not awaiting the status. The sensor acts on this write
        // at once and reboots into its bootloader, so the acknowledgement it
        // owes us is never sent — waiting for it left the app spinning on a
        // response that could not arrive while the sensor had already gone.
        // The same reasoning is why stopLogging()'s reboot uses `try?`.
        Task { try? await gsp.putSystemMode(12) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await gsp.disconnect()
    }

    public func downloadEntry(_ entry: LogbookEntryInfo, progress: @escaping (Double) -> Void) async throws -> RawSessionData {
        guard let logId = UInt32(entry.id) else {
            throw SensorError.transferFailed("Identifiant de log invalide : \(entry.id)")
        }
        let totalSize = max(entry.sizeBytes ?? 1, 1)
        let startedAt = Date()
        let sbemData = try await gsp.fetchLog(id: logId) { bytesReceived in
            DispatchQueue.main.async { progress(min(0.95, Double(bytesReceived) / Double(totalSize))) }
        }
        // Measured on the bytes that actually arrived, not on the listing's
        // announced size: the two disagree, and the announced one is the less
        // trustworthy of the pair.
        lastTransfer = TransferStats(bytes: sbemData.count, seconds: Date().timeIntervalSince(startedAt))
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
