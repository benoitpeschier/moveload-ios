import Foundation
import CoreBluetooth
import MoveLoadCore

/// Client for Movesense's "GSP" (GATT SensorData Protocol) — a custom binary
/// GATT protocol, completely separate from the MDS/Whiteboard-over-BLE
/// protocol `MDSWrapper` speaks. Ported line-for-line from Movesense's
/// official `python-datalogger-tool` (`sensor_command.py`), which is
/// confirmed working against this exact sensor's stock firmware
/// (2026-08-13) — `doPut` against `Mem/DataLogger` via MDSWrapper fails
/// unconditionally (see `MovesenseSensorService`), but this protocol
/// configures/starts/stops on-device recording and fetches logs
/// successfully. This client owns its own `CBCentralManager` /
/// `CBPeripheral` — it does not go through MDSWrapper at all.
public actor MovesenseGSPClient {
    public enum GSPError: Error, LocalizedError {
        case notFound
        case connectionFailed(String)
        case commandFailed(command: String, statusCode: UInt16)
        case unexpectedResponse(String)
        case timeout(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: return "Capteur GSP introuvable."
            case .connectionFailed(let reason): return "Connexion GSP échouée : \(reason)"
            case .commandFailed(let command, let statusCode): return "Commande GSP \(command) a échoué (code \(statusCode))."
            case .unexpectedResponse(let detail): return "Réponse GSP inattendue : \(detail)"
            case .timeout(let detail): return "Délai dépassé : \(detail)"
            }
        }
    }

    public struct LogbookEntry: Sendable, Equatable {
        public let id: UInt32
        public let lastModified: UInt32
        public let size: UInt64
    }

    static let serviceUUID = CBUUID(string: "34802252-7185-4d5d-b431-630e7050e8f0")
    static let advertisedServiceUUID = CBUUID(string: "FDF3")
    private static let writeCharUUID = CBUUID(string: "34800001-7185-4d5d-b431-630e7050e8f0")
    private static let notifyCharUUID = CBUUID(string: "34800002-7185-4d5d-b431-630e7050e8f0")

    private enum Command: UInt8 {
        case hello = 0
        case subscribe = 1
        case unsubscribe = 2
        case fetchLog = 3
        case get = 4
        case clearLogbook = 5
        case putDataLoggerConfig = 6
        case putSystemMode = 7
        case putUtcTime = 8
        case putDataLoggerState = 9
    }

    private enum ResponseCode: UInt8 {
        case commandResponse = 1
        case data = 2
        case dataPart2 = 3
    }

    private let delegate: Delegate
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    /// Pending single-shot command response — mirrors the Python client's
    /// single-item response queue (commands are sent sequentially, never
    /// pipelined). Holds the raw notification bytes for the next
    /// COMMAND_RESPONSE.
    private var pendingResponse: CheckedContinuation<Data, Error>?
    /// While a FETCH_LOG is in flight, DATA/DATA_PART2 notifications are
    /// routed here instead of `pendingResponse`.
    private var fetchAccumulator: FetchAccumulator?

    /// Fires when the peripheral disconnects — expectedly (explicit
    /// `disconnect()`) or not (e.g. the sensor reboots itself after
    /// `putSystemMode(5)`, or goes out of range).
    public var onDisconnect: (@Sendable () -> Void)?

    public func setOnDisconnect(_ handler: @escaping @Sendable () -> Void) {
        self.onDisconnect = handler
    }

    public init() {
        self.delegate = Delegate()
        delegate.bind(to: self)
    }

    // MARK: - Connection

    /// Scans for a peripheral advertising the GSP service whose name ends
    /// with `serialSuffix`, connects, and enables notifications. Filters the
    /// scan on the short `FDF3` UUID — verified against a real device
    /// (2026-08-11, see `MovesenseSensorService`) to be what's actually in
    /// the ~31-byte advertisement payload; the full 128-bit GSP service
    /// UUID only shows up in the GATT table after connecting.
    public func connect(serialSuffix: String, timeout: TimeInterval = 10) async throws {
        let found = try await delegate.scanForDevice(nameSuffix: serialSuffix, serviceUUID: Self.advertisedServiceUUID, timeout: timeout)
        try await connect(peripheral: found)
    }

    /// Connects directly to an already-discovered peripheral, skipping the
    /// scan step — used when `MovesenseSensorService` already found it via
    /// its own scan.
    public func connect(peripheral: CBPeripheral) async throws {
        self.peripheral = peripheral
        try await delegate.connect(peripheral)
        let (write, _) = try await delegate.discoverGSPCharacteristics(peripheral)
        self.writeCharacteristic = write
        try await delegate.enableNotifications(peripheral, characteristicUUID: Self.notifyCharUUID)

        // The sensor's RTC resets to 2015-01-01 whenever it loses power
        // (confirmed on this exact device via Showcase's "Sensor info").
        // The official Python tool sets it on every connect — best-effort
        // so a clock-set hiccup doesn't block the whole connection.
        let nowMicroseconds = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        try? await setUtcTime(microsecondsSince1970: nowMicroseconds)
    }

    public func disconnect() async {
        if let peripheral {
            await delegate.disconnect(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
    }

    // MARK: - Commands

    @discardableResult
    public func hello() async throws -> (serialNumber: String, productName: String, appName: String, appVersion: String) {
        let ref = nextReference()
        let response = try await send(command: .hello, reference: ref, payload: Data(), expectsStatusCode: false)
        guard response.data.count >= 1 else {
            throw GSPError.unexpectedResponse("HELLO: réponse trop courte")
        }
        // Byte 0 is the protocol version; the rest is null-terminated UTF-8 strings.
        let stringsData = response.data.dropFirst()
        let strings = stringsData.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        return (
            serialNumber: strings.count > 0 ? strings[0] : "",
            productName: strings.count > 1 ? strings[1] : "",
            appName: strings.count > 3 ? strings[3] : "",
            appVersion: strings.count > 4 ? strings[4] : ""
        )
    }

    public func getDataLoggerState() async throws -> UInt8 {
        let data = try await get("/Mem/DataLogger/State")
        guard let first = data.first else { throw GSPError.unexpectedResponse("État DataLogger vide") }
        return first
    }

    public func get(_ path: String) async throws -> Data {
        let ref = nextReference()
        var payload = Data(path.utf8)
        payload.append(0)
        let response = try await send(command: .get, reference: ref, payload: payload, expectsStatusCode: true)
        return response.data
    }

    /// Configures which resources the DataLogger records. `/Time/Detailed`
    /// is added automatically, matching the official tool's behaviour.
    public func putDataLoggerConfig(paths: [String]) async throws {
        var payload = Data()
        for path in paths + ["/Time/Detailed"] {
            payload.append(contentsOf: Array(path.utf8))
            payload.append(0)
        }
        let ref = nextReference()
        _ = try await send(command: .putDataLoggerConfig, reference: ref, payload: payload, expectsStatusCode: true)
    }

    /// `state`: 3 = start logging, 2 = stop logging (Ready).
    public func putDataLoggerState(_ state: UInt8) async throws {
        let ref = nextReference()
        _ = try await send(command: .putDataLoggerState, reference: ref, payload: Data([state]), expectsStatusCode: true)
    }

    /// `mode` 5 reboots the sensor (used after stopping, matching the
    /// official tool's stop flow, to start a fresh log next time).
    public func putSystemMode(_ mode: UInt8) async throws {
        let ref = nextReference()
        // Accept 202 (Accepted) in addition to 200, matching the official tool.
        _ = try await send(command: .putSystemMode, reference: ref, payload: Data([mode]), expectsStatusCode: true, acceptedStatusCodes: [200, 202])
    }

    public func setUtcTime(microsecondsSince1970: UInt64) async throws {
        let ref = nextReference()
        var payload = Data(count: 8)
        payload.withUnsafeMutableBytes { $0.storeBytes(of: microsecondsSince1970.littleEndian, as: UInt64.self) }
        _ = try await send(command: .putUtcTime, reference: ref, payload: payload, expectsStatusCode: true)
    }

    public func eraseMemory() async throws {
        let ref = nextReference()
        _ = try await send(command: .clearLogbook, reference: ref, payload: Data(), expectsStatusCode: true)
    }

    public func getLogbookEntries() async throws -> [LogbookEntry] {
        let ref = nextReference()
        var payload = Data("/Mem/Logbook/entries".utf8)
        payload.append(0)
        // This resource's response doesn't carry a status code the same way
        // a generic GET does — the raw notification bytes (header + 16-byte
        // records) are what we need, so read the full raw response.
        let raw = try await sendRaw(command: .get, reference: ref, payload: payload)
        return Self.parseLogbookEntries(raw)
    }

    /// Fetches one logbook entry's raw SBEM bytes. `progress` receives the
    /// running byte count as data streams in.
    public func fetchLog(id: UInt32, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        let ref = nextReference()
        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { $0.storeBytes(of: id.littleEndian, as: UInt32.self) }

        _ = try await send(command: .fetchLog, reference: ref, payload: payload, expectsStatusCode: true)

        return try await withCheckedThrowingContinuation { continuation in
            fetchAccumulator = FetchAccumulator(progress: progress, completion: continuation)
        }
    }

    // MARK: - Internal plumbing

    private var referenceCounter: UInt8 = 100
    private func nextReference() -> UInt8 {
        referenceCounter = referenceCounter == .max ? 100 : referenceCounter + 1
        return referenceCounter
    }

    private func send(
        command: Command,
        reference: UInt8,
        payload: Data,
        expectsStatusCode: Bool,
        acceptedStatusCodes: Set<UInt16> = [200]
    ) async throws -> (statusCode: UInt16?, data: Data) {
        let raw = try await sendRaw(command: command, reference: reference, payload: payload)
        // raw layout for COMMAND_RESPONSE: [responseCode, reference, statusCode(2 LE)?, data...]
        guard raw.count >= 2, raw[raw.startIndex] == ResponseCode.commandResponse.rawValue else {
            throw GSPError.unexpectedResponse("code de réponse inattendu pour \(command)")
        }
        if expectsStatusCode {
            guard raw.count >= 4 else { throw GSPError.unexpectedResponse("\(command): réponse trop courte") }
            let statusCode = UInt16(raw[raw.startIndex + 2]) | (UInt16(raw[raw.startIndex + 3]) << 8)
            guard acceptedStatusCodes.contains(statusCode) else {
                throw GSPError.commandFailed(command: "\(command)", statusCode: statusCode)
            }
            let data = raw.count > 4 ? raw.suffix(from: raw.startIndex + 4) : Data()
            return (statusCode, Data(data))
        } else {
            let data = raw.count > 2 ? raw.suffix(from: raw.startIndex + 2) : Data()
            return (nil, Data(data))
        }
    }

    /// Sends a command and returns the raw notification bytes for the
    /// matching COMMAND_RESPONSE, without interpreting status code framing
    /// (used for HELLO and for the logbook-entries GET, whose payload shape
    /// differs from a generic status+data GET).
    private func sendRaw(command: Command, reference: UInt8, payload: Data) async throws -> Data {
        guard let peripheral, let writeCharacteristic else {
            throw GSPError.connectionFailed("non connecté")
        }
        var commandBytes = Data([command.rawValue, reference])
        commandBytes.append(payload)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingResponse = continuation
            let delegate = self.delegate
            Task { await delegate.writeCommand(commandBytes, to: writeCharacteristic, on: peripheral) }
        }
    }

    private static func parseLogbookEntries(_ raw: Data) -> [LogbookEntry] {
        let headerSize = 5
        let entrySize = 16
        guard raw.count > headerSize else { return [] }
        let entryData = raw.suffix(from: raw.startIndex + headerSize)
        var entries: [LogbookEntry] = []
        var offset = entryData.startIndex
        while offset + entrySize <= entryData.endIndex {
            let bytes = entryData[offset..<(offset + entrySize)]
            let id = Self.readUInt32LE(bytes, at: bytes.startIndex)
            let lastModified = Self.readUInt32LE(bytes, at: bytes.startIndex + 4)
            let size = Self.readUInt64LE(bytes, at: bytes.startIndex + 8)
            entries.append(LogbookEntry(id: id, lastModified: lastModified, size: size))
            offset += entrySize
        }
        return entries
    }

    private static func readUInt32LE(_ data: Data.SubSequence, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * i) }
        return value
    }

    private static func readUInt64LE(_ data: Data.SubSequence, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << (8 * i) }
        return value
    }

    fileprivate func handlePeripheralDisconnected() {
        peripheral = nil
        writeCharacteristic = nil
        if let pending = pendingResponse {
            pendingResponse = nil
            pending.resume(throwing: GSPError.connectionFailed("déconnecté"))
        }
        onDisconnect?()
    }

    fileprivate func handleNotification(_ data: Data) {
        guard let responseCodeByte = data.first, let responseCode = ResponseCode(rawValue: responseCodeByte) else { return }

        switch responseCode {
        case .commandResponse:
            if let pending = pendingResponse {
                pendingResponse = nil
                pending.resume(returning: data)
            }
        case .data, .dataPart2:
            guard data.count >= 6 else { return } // responseCode(1) + reference(1) + offset(4)
            let offset = Self.readUInt32LE(data, at: data.startIndex + 2)
            let bytes = data.suffix(from: data.startIndex + 6)
            fetchAccumulator?.append(offset: Int(offset), bytes: Data(bytes))
        }
    }
}

/// Accumulates FETCH_LOG data packets (which arrive with an explicit byte
/// offset, not necessarily in order) into a single buffer, matching the
/// official tool's "seek + write" semantics on the output file. An empty
/// data packet signals end-of-log.
private final class FetchAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private let progress: (@Sendable (Int) -> Void)?
    private var completion: CheckedContinuation<Data, Error>?

    init(progress: (@Sendable (Int) -> Void)?, completion: CheckedContinuation<Data, Error>) {
        self.progress = progress
        self.completion = completion
    }

    func append(offset: Int, bytes: Data) {
        guard let completion else { return }
        if bytes.isEmpty {
            self.completion = nil
            completion.resume(returning: buffer)
            return
        }
        let endOffset = offset + bytes.count
        if buffer.count < endOffset {
            buffer.append(Data(repeating: 0, count: endOffset - buffer.count))
        }
        buffer.replaceSubrange(offset..<endOffset, with: bytes)
        progress?(endOffset)
    }
}

/// Bridges CoreBluetooth's delegate callbacks into async/await, and owns the
/// actual `CBCentralManager`/`CBPeripheralDelegate` conformance (an `actor`
/// can't itself conform to an `@objc` protocol). `@MainActor`-isolated
/// because `CBCentralManager(delegate:queue: nil)` delivers callbacks on the
/// main queue — this keeps every read/write of the continuation-storage
/// properties on that same queue instead of racing with the owning actor's
/// own executor.
@MainActor
private final class Delegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    nonisolated override init() {
        super.init()
    }

    private var centralManager: CBCentralManager?
    private weak var owner: MovesenseGSPClient?

    private var scanContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var scanNameSuffix: String?
    private var scanTimeoutTask: Task<Void, Never>?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<(CBCharacteristic, CBCharacteristic), Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var pendingWriteChar: CBCharacteristic?
    private var pendingNotifyChar: CBCharacteristic?

    /// `nonisolated` so `MovesenseGSPClient.init()` (synchronous) can call
    /// it directly — safe because it runs once, before any BLE callback
    /// could plausibly have fired yet.
    nonisolated func bind(to client: MovesenseGSPClient) {
        Task { @MainActor in self.owner = client }
    }

    func scanForDevice(nameSuffix: String, serviceUUID: CBUUID, timeout: TimeInterval) async throws -> CBPeripheral {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        scanNameSuffix = nameSuffix
        return try await withCheckedThrowingContinuation { continuation in
            self.scanContinuation = continuation
            if centralManager?.state == .poweredOn {
                centralManager?.scanForPeripherals(withServices: [serviceUUID], options: nil)
            }
            scanTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutScan()
            }
        }
    }

    private func timeoutScan() {
        centralManager?.stopScan()
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(throwing: MovesenseGSPClient.GSPError.notFound)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, scanContinuation != nil {
            central.scanForPeripherals(withServices: [MovesenseGSPClient.advertisedServiceUUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let suffix = scanNameSuffix, let name = peripheral.name, name.hasSuffix(suffix) else { return }
        scanTimeoutTask?.cancel()
        central.stopScan()
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(returning: peripheral)
        }
    }

    func connect(_ peripheral: CBPeripheral) async throws {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            centralManager?.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed(error?.localizedDescription ?? "échec inconnu"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { [owner] in await owner?.handlePeripheralDisconnected() }
    }

    func disconnect(_ peripheral: CBPeripheral) async {
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    func discoverGSPCharacteristics(_ peripheral: CBPeripheral) async throws -> (CBCharacteristic, CBCharacteristic) {
        try await withCheckedThrowingContinuation { continuation in
            self.discoverContinuation = continuation
            peripheral.discoverServices([MovesenseGSPClient.serviceUUID])
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == MovesenseGSPClient.serviceUUID }) else {
            discoverContinuation?.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed("service GSP introuvable"))
            discoverContinuation = nil
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard service.uuid == MovesenseGSPClient.serviceUUID else { return }
        let write = service.characteristics?.first { $0.uuid.uuidString == "34800001-7185-4D5D-B431-630E7050E8F0" }
        let notify = service.characteristics?.first { $0.uuid.uuidString == "34800002-7185-4D5D-B431-630E7050E8F0" }
        guard let write, let notify else {
            discoverContinuation?.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed("caractéristiques GSP introuvables"))
            discoverContinuation = nil
            return
        }
        pendingWriteChar = write
        pendingNotifyChar = notify
        if let continuation = discoverContinuation {
            discoverContinuation = nil
            continuation.resume(returning: (write, notify))
        }
    }

    func enableNotifications(_ peripheral: CBPeripheral, characteristicUUID: CBUUID) async throws {
        guard let notifyChar = pendingNotifyChar else {
            throw MovesenseGSPClient.GSPError.connectionFailed("caractéristique de notification manquante")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.notifyContinuation = continuation
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            notifyContinuation?.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed(error.localizedDescription))
        } else {
            notifyContinuation?.resume()
        }
        notifyContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid.uuidString == "34800002-7185-4D5D-B431-630E7050E8F0", let data = characteristic.value else { return }
        Task { [owner] in
            await owner?.handleNotification(data)
        }
    }

    func writeCommand(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
}
