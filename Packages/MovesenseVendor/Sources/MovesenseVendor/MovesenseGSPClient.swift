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
            case .connectionFailed(let reason): return String(localized: "Connexion GSP échouée : \(reason)", bundle: .module)
            case .commandFailed(let command, let statusCode): return String(localized: "Commande GSP \(command) a échoué (code \(statusCode)).", bundle: .module)
            case .unexpectedResponse(let detail): return String(localized: "Réponse GSP inattendue : \(detail)", bundle: .module)
            case .timeout(let detail): return String(localized: "Délai dépassé : \(detail)", bundle: .module)
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
    private var pendingResponseTimeoutTask: Task<Void, Never>?

    /// Live subscriptions, by the reference they were opened with.
    ///
    /// Subscription data and logbook data share the DATA response code but are
    /// framed differently — a download inserts a four-byte offset after the
    /// reference, a subscription puts its payload there directly. The
    /// reference is the only thing that tells them apart, which is why they
    /// are routed by it rather than by shape.
    private var subscriptions: [UInt8: @Sendable (Data) -> Void] = [:]
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
        // Close the subscriptions politely while the link is still up, so the
        // sensor frees its stream slots rather than waiting to notice the
        // disconnection. It only has four.
        for reference in subscriptions.keys {
            _ = try? await send(command: .unsubscribe, reference: reference,
                                payload: Data(), expectsStatusCode: false)
        }
        subscriptions.removeAll()

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
            throw GSPError.unexpectedResponse(String(localized: "HELLO: réponse trop courte", bundle: .module))
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
        guard let first = data.first else { throw GSPError.unexpectedResponse(String(localized: "État DataLogger vide", bundle: .module)) }
        return first
    }

    /// Whether the sensor has stopped logging because its flash is nearly
    /// full. Firmware 2.2 and later halts the DataLogger around 123 MB of the
    /// 128 MB available, rather than letting write performance collapse — so
    /// this is the difference between "no room" and "something else went
    /// wrong" when a recording fails to appear.
    public func isLogbookFull() async throws -> Bool {
        let data = try await get("/Mem/Logbook/IsFull")
        guard let first = data.first else {
            throw GSPError.unexpectedResponse(String(localized: "État IsFull vide", bundle: .module))
        }
        return first != 0
    }

    /// The auto-start firmware's own view of itself: the flags its decisions
    /// rest on, and a journal of the last sixteen it took.
    ///
    /// Answered by our firmware directly rather than proxied to a whiteboard
    /// resource — which is the point. A resource would report what the *sensor*
    /// is doing, and that was never the unknown: the unknown is what the module
    /// deciding on it believed at the time.
    ///
    /// Available from firmware 1.13.0. Earlier images answer 404, which
    /// surfaces as an error rather than as an empty journal.
    public func getMoveLoadState() async throws -> Data {
        // Not `get(_:)`: that one expects the status code the firmware puts in
        // front of a whiteboard resource's answer. This path is answered by our
        // own firmware from its own memory, like HELLO, and carries no status —
        // the same split as on the sensor side, where proxied paths go through
        // onGetResult and ours are served on the spot.
        let ref = nextReference()
        var payload = Data("/MoveLoad/State".utf8)
        payload.append(0)
        let response = try await send(command: .get, reference: ref,
                                      payload: payload, expectsStatusCode: false)
        return response.data
    }

    /// Remaining charge, 0–100 %.
    ///
    /// The sensor answers 503 while it cannot take the measurement, which the
    /// send below surfaces as an error rather than a figure — a battery level
    /// invented when none could be read is worse than none at all.
    public func getBatteryPercent() async throws -> Int {
        let data = try await get("/System/Energy/Level")
        guard let first = data.first else {
            throw GSPError.unexpectedResponse("Niveau de batterie vide")
        }
        return Int(first)
    }

    /// Opens a live subscription on `path`, delivering each notification's raw
    /// payload to `onData`. Returns the reference to close it with.
    ///
    /// The payload is SBEM, the same encoding the logbook uses — but without
    /// the file's leading descriptor table, so `MovesenseSBEMDecoder.decode`
    /// cannot read it. What the bytes actually contain is deliberately left to
    /// the caller for now: it will be read off the wire rather than guessed.
    @discardableResult
    public func subscribe(path: String, onData: @escaping @Sendable (Data) -> Void) async throws -> UInt8 {
        let ref = nextReference()
        subscriptions[ref] = onData
        var payload = Data(path.utf8)
        payload.append(0)
        do {
            _ = try await send(command: .subscribe, reference: ref, payload: payload, expectsStatusCode: true)
        } catch {
            subscriptions[ref] = nil
            throw error
        }
        return ref
    }

    public func unsubscribe(reference: UInt8) async {
        subscriptions[reference] = nil
        // Sent, not awaited. Nothing downstream depends on the answer, and
        // firmware that does not acknowledge it — as ours did not until 1.6.0 —
        // would otherwise cost a full command timeout at the very moment the
        // athlete is waiting for their result.
        let peripheralRef = peripheral
        let write = writeCharacteristic
        if let peripheralRef, let write {
            let bytes = Data([Command.unsubscribe.rawValue, reference])
            let delegate = self.delegate
            Task { await delegate.writeCommand(bytes, to: write, on: peripheralRef) }
        }
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

    /// Every stored recording, following the resource's pagination.
    ///
    /// Only a handful of entries fit in one response — four, in practice on
    /// this sensor. The Movesense API signals that with status 100 ("not all
    /// log entries fit in the list, please ask again with StartAfterId") and
    /// expects the caller to continue from the last id seen. Ignoring that, as
    /// this used to, made every recording past the fourth invisible: a real
    /// session went missing that way (2026-08-17), and the athlete reasonably
    /// concluded the sensor had failed to record it.
    public func getLogbookEntries() async throws -> [LogbookEntry] {
        var payload = Data("/Mem/Logbook/entries".utf8)
        payload.append(0)
        let raw = try await sendRaw(command: .get, reference: nextReference(), payload: payload)
        let page = Self.parseLogbookEntries(raw)
        moreEntriesExistBeyondListing = page.isPartial
        return page.entries
    }

    /// True when the sensor answered 100, meaning it holds recordings its
    /// listing won't show. There is no way to page to them: the documented
    /// `StartAfterId` continuation is a query parameter, and GSP carries only
    /// a bare path (confirmed against the sensor, 2026-08-17: status 400).
    /// Reaching them means fetching by id — see `fetchLogIfPresent`.
    public private(set) var moreEntriesExistBeyondListing = false

    /// Fetches a recording by id, returning nil when the sensor has no such
    /// log. This is the only way to reach recordings past the fourth: the
    /// listing caps at four and GSP has no query-parameter mechanism, so its
    /// documented `StartAfterId` continuation is unreachable (confirmed
    /// against the sensor, 2026-08-17: status 400). The FETCH_LOG
    /// acknowledgement is what distinguishes a real log from an absent one.
    public func fetchLogIfPresent(id: UInt32, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data? {
        do {
            return try await fetchLog(id: id, progress: progress)
        } catch let error as GSPError {
            // A rejected acknowledgement means no log at that id; anything
            // else is a real failure worth surfacing.
            if case .commandFailed = error { return nil }
            throw error
        }
    }

    /// Fetches one logbook entry's raw SBEM bytes. `progress` receives the
    /// running byte count as data streams in.
    public func fetchLog(id: UInt32, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        let ref = nextReference()
        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { $0.storeBytes(of: id.littleEndian, as: UInt32.self) }

        // The accumulator MUST exist before the command goes out: the sensor
        // starts streaming DATA packets as soon as it acknowledges FETCH_LOG,
        // and notifications reach this actor through their own Tasks. Setting
        // it up after awaiting the ack (as this used to) left a window where
        // the first packets — including offset 0, which carries the
        // "SBEM0112" header — were dropped on a nil accumulator, and the
        // zero-filled gap then failed to decode as "en-tête SBEM non reconnu".
        return try await withCheckedThrowingContinuation { continuation in
            fetchAccumulator = FetchAccumulator(progress: progress, completion: continuation)
            Task {
                do {
                    _ = try await send(command: .fetchLog, reference: ref, payload: payload, expectsStatusCode: true)
                } catch {
                    failPendingFetch(with: error)
                }
            }
        }
    }

    /// Aborts an in-flight fetch (the FETCH_LOG command itself failed, so no
    /// DATA packets will ever arrive to complete it).
    private func failPendingFetch(with error: Error) {
        guard let accumulator = fetchAccumulator else { return }
        fetchAccumulator = nil
        accumulator.fail(error)
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
            throw GSPError.unexpectedResponse(String(localized: "code de réponse inattendu pour \(command)", bundle: .module))
        }
        if expectsStatusCode {
            guard raw.count >= 4 else { throw GSPError.unexpectedResponse(String(localized: "\(command): réponse trop courte", bundle: .module)) }
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
            throw GSPError.connectionFailed(String(localized: "non connecté", bundle: .module))
        }
        var commandBytes = Data([command.rawValue, reference])
        commandBytes.append(payload)

        // One command at a time, and say so rather than clobbering. There is a
        // single pending continuation: a second command issued before the
        // first answers overwrites it, the first never resumes, and its
        // timeout task is overwritten too — so the caller waits for ever with
        // no error. That is exactly what two `async let` reads did to the
        // diagnostics screen, and a spinner that never stops is the least
        // diagnosable failure there is.
        if pendingResponse != nil {
            throw GSPError.unexpectedResponse(
                String(localized: "une commande est déjà en cours", bundle: .module))
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingResponse = continuation
            let delegate = self.delegate
            Task { await delegate.writeCommand(commandBytes, to: writeCharacteristic, on: peripheral) }
            // A sensor that accepts the connection and exposes GSP can still
            // never answer — nothing in BLE obliges it to, and the write
            // itself succeeds. Without this the app waited for ever on the
            // very first command after connecting.
            pendingResponseTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.commandTimeout * 1_000_000_000))
                await self?.failPendingResponse(command: "\(command)")
            }
        }
    }

    /// Seconds allowed for one GSP command to be answered. A logbook download
    /// is not covered by this — it streams through its own accumulator.
    private static let commandTimeout: TimeInterval = 15

    private func failPendingResponse(command: String) {
        guard let continuation = pendingResponse else { return }
        pendingResponse = nil
        continuation.resume(throwing: GSPError.timeout(
            String(localized: "le capteur n'a pas répondu à \(command). Il est connecté mais ne parle pas — coupe le Bluetooth et rallume-le, ou redémarre le capteur en le sortant de la sangle.", bundle: .module)))
    }

    /// `isPartial` reflects status 100, meaning more entries remain and the
    /// caller should ask again anchored on the last id.
    private static func parseLogbookEntries(_ raw: Data) -> (entries: [LogbookEntry], isPartial: Bool) {
        let headerSize = 5
        let entrySize = 16
        guard raw.count > headerSize else { return ([], false) }

        // Layout: responseCode(1) + reference(1) + statusCode(2 LE) + 1 byte
        // preceding the records.
        let status = UInt16(raw[raw.startIndex + 2]) | (UInt16(raw[raw.startIndex + 3]) << 8)

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
        return (entries, status == 100)
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
        // Handlers for a connection that no longer exists. Left in place they
        // would take delivery of data belonging to the next one, since routing
        // is by reference and the counter keeps running.
        subscriptions.removeAll()
        pendingResponseTimeoutTask?.cancel()
        if let pending = pendingResponse {
            pendingResponse = nil
            pending.resume(throwing: GSPError.connectionFailed(String(localized: "déconnecté", bundle: .module)))
        }
        onDisconnect?()
    }

    fileprivate func handleNotification(_ data: Data) {
        guard let responseCodeByte = data.first, let responseCode = ResponseCode(rawValue: responseCodeByte) else { return }

        switch responseCode {
        case .commandResponse:
            pendingResponseTimeoutTask?.cancel()
            if let pending = pendingResponse {
                pendingResponse = nil
                pending.resume(returning: data)
            }
        case .data, .dataPart2:
            guard data.count >= 2 else { return }
            let reference = data[data.startIndex + 1]
            if let deliver = subscriptions[reference] {
                // Subscription framing: payload straight after the reference.
                deliver(Data(data.suffix(from: data.startIndex + 2)))
                return
            }
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
    /// Total bytes actually written by packets. Gaps are zero-filled to keep
    /// out-of-order offsets working, so this is what distinguishes "buffer is
    /// complete" from "buffer has holes we invented" — see `append`.
    private var bytesWritten = 0

    init(progress: (@Sendable (Int) -> Void)?, completion: CheckedContinuation<Data, Error>) {
        self.progress = progress
        self.completion = completion
    }

    func append(offset: Int, bytes: Data) {
        guard let completion else { return }
        if bytes.isEmpty {
            self.completion = nil
            // A missing packet would otherwise surface far downstream as a
            // confusing decode failure on zero-filled bytes, so refuse the
            // whole transfer rather than hand back a plausible-looking buffer.
            // `>=` not `==`: a re-sent or overlapping packet double-counts,
            // which is harmless — only a shortfall means real zero-filled holes.
            guard bytesWritten >= buffer.count else {
                completion.resume(throwing: MovesenseGSPClient.GSPError.unexpectedResponse(
                    "transfert incomplet : \(buffer.count - bytesWritten) octet(s) manquant(s) sur \(buffer.count)."
                ))
                return
            }
            completion.resume(returning: buffer)
            return
        }
        let endOffset = offset + bytes.count
        if buffer.count < endOffset {
            buffer.append(Data(repeating: 0, count: endOffset - buffer.count))
        }
        buffer.replaceSubrange(offset..<endOffset, with: bytes)
        bytesWritten += bytes.count
        progress?(endOffset)
    }

    func fail(_ error: Error) {
        guard let completion else { return }
        self.completion = nil
        completion.resume(throwing: error)
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

    // Every step below waits on a CoreBluetooth callback that is not
    // guaranteed to arrive: a sensor whose links are all taken never answers a
    // connect, and iOS reports nothing. Without these, the app spun on
    // "Connexion…" for ever with no message — the worst failure to hand an
    // athlete, since it says neither what is wrong nor what to try.
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var connectingPeripheral: CBPeripheral?
    private var discoverContinuation: CheckedContinuation<(CBCharacteristic, CBCharacteristic), Error>?
    private var discoverTimeoutTask: Task<Void, Never>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    /// Separate from `notifyContinuation`: disabling notifications on the way
    /// out must not fail a disconnect, so it never throws and always finishes.
    private var notifyOffContinuation: CheckedContinuation<Void, Never>?
    private var notifyOffTimeoutTask: Task<Void, Never>?
    private var notifyTimeoutTask: Task<Void, Never>?
    private var pendingWriteChar: CBCharacteristic?
    private var pendingNotifyChar: CBCharacteristic?

    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private var disconnectTimeoutTask: Task<Void, Never>?

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
            self.connectingPeripheral = peripheral
            centralManager?.connect(peripheral, options: nil)
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Delegate.stepTimeout * 1_000_000_000))
                await self?.failConnect()
            }
        }
    }

    /// Seconds allowed for one CoreBluetooth step. Generous: a first connect
    /// after a firmware change can be slow while iOS rebuilds its GATT cache.
    static let stepTimeout: TimeInterval = 20

    private func failConnect() {
        if let continuation = connectContinuation {
            connectContinuation = nil
            if let connectingPeripheral { centralManager?.cancelPeripheralConnection(connectingPeripheral) }
            continuation.resume(throwing: MovesenseGSPClient.GSPError.timeout(
                String(localized: "connexion au capteur. Un autre appareil le tient peut-être déjà — montre, nRF Connect, ou l'app restée ouverte en arrière-plan.", bundle: .module)))
        }
    }

    private func failDiscover() {
        if let continuation = discoverContinuation {
            discoverContinuation = nil
            continuation.resume(throwing: MovesenseGSPClient.GSPError.timeout(String(localized: "découverte des services GSP", bundle: .module)))
        }
    }

    private func failNotify() {
        if let continuation = notifyContinuation {
            notifyContinuation = nil
            continuation.resume(throwing: MovesenseGSPClient.GSPError.timeout("activation des notifications GSP"))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutTask?.cancel()
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed(error?.localizedDescription ?? String(localized: "échec inconnu", bundle: .module)))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finishDisconnect()
        Task { [owner] in await owner?.handlePeripheralDisconnected() }
    }

    /// Tears the link down and only returns once CoreBluetooth confirms it.
    /// Two details matter, and both were missing before: the notification
    /// subscription is dropped first (iOS can otherwise hold the link open
    /// for a still-subscribed characteristic), and the call waits for
    /// `didDisconnectPeripheral` instead of returning straight after
    /// `cancelPeripheralConnection` — which used to let the UI claim
    /// "déconnecté" while the sensor was in fact still attached, so nothing
    /// else (another Mac, another phone) could take it over.
    func disconnect(_ peripheral: CBPeripheral) async {
        guard let central = centralManager else { return }
        // Already down (the sensor reboots itself after stopLogging, for
        // one) — no callback would ever come, so don't sit out the timeout.
        guard peripheral.state != .disconnected else {
            pendingNotifyChar = nil
            pendingWriteChar = nil
            return
        }

        // Wait for the descriptor write to land before tearing the link down.
        //
        // Fire-and-forget, the cancel below happened in the same turn and the
        // write usually never reached the sensor. That matters more than it
        // looks: the firmware reads this very descriptor as "a phone is using
        // me", and a link dropped without it left the sensor believing so for
        // ever — the strap going on armed nothing, with no LED and no
        // recording. Firmware 1.10.0 also clears the flag on disconnect, for
        // the drops no app can be polite about; this is the near half of the
        // same fix, and it works on a sensor that has not been reflashed.
        if let notify = pendingNotifyChar, notify.isNotifying {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                notifyOffContinuation = continuation
                peripheral.setNotifyValue(false, for: notify)
                notifyOffTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self?.finishNotifyOff()
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            disconnectContinuation = continuation
            central.cancelPeripheralConnection(peripheral)
            // Don't hang the UI forever if the callback never lands; the
            // cancel has been issued either way.
            disconnectTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.finishDisconnect()
            }
        }

        pendingNotifyChar = nil
        pendingWriteChar = nil
    }

    private func finishDisconnect() {
        disconnectTimeoutTask?.cancel()
        disconnectTimeoutTask = nil
        if let continuation = disconnectContinuation {
            disconnectContinuation = nil
            continuation.resume()
        }
    }

    func discoverGSPCharacteristics(_ peripheral: CBPeripheral) async throws -> (CBCharacteristic, CBCharacteristic) {
        try await withCheckedThrowingContinuation { continuation in
            self.discoverContinuation = continuation
            peripheral.discoverServices([MovesenseGSPClient.serviceUUID])
            discoverTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Delegate.stepTimeout * 1_000_000_000))
                await self?.failDiscover()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == MovesenseGSPClient.serviceUUID }) else {
            discoverTimeoutTask?.cancel()
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
        discoverTimeoutTask?.cancel()
        guard let write, let notify else {
            discoverContinuation?.resume(throwing: MovesenseGSPClient.GSPError.connectionFailed(String(localized: "caractéristiques GSP introuvables", bundle: .module)))
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
            throw MovesenseGSPClient.GSPError.connectionFailed(String(localized: "caractéristique de notification manquante", bundle: .module))
        }

        // Turn it off first when iOS believes it is already on.
        //
        // CoreBluetooth skips writing the descriptor if its own cached view
        // says the characteristic is already notifying — so the app is told
        // notifications are enabled while the sensor never saw the write, and
        // every answer it sends goes nowhere. That is what a reconnection after
        // an automatic recording looked like: connect fine, then the first
        // command times out with no reply, and quitting the app "fixed" it
        // because that is what clears the cached view.
        if notifyChar.isNotifying {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.notifyContinuation = continuation
                peripheral.setNotifyValue(false, for: notifyChar)
                notifyTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Delegate.stepTimeout * 1_000_000_000))
                    await self?.failNotify()
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.notifyContinuation = continuation
            peripheral.setNotifyValue(true, for: notifyChar)
            notifyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Delegate.stepTimeout * 1_000_000_000))
                await self?.failNotify()
            }
        }
    }

    private func finishNotifyOff() {
        notifyOffTimeoutTask?.cancel()
        notifyOffTimeoutTask = nil
        notifyOffContinuation?.resume()
        notifyOffContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if notifyOffContinuation != nil {
            finishNotifyOff()
            return
        }
        notifyTimeoutTask?.cancel()
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
