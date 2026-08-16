import Foundation
import MoveLoadCore

/// Stands in for the real Movesense SDK integration until SDK access is available.
/// Conforms to the exact same `SensorService` protocol, so swapping it out later
/// for a CoreBluetooth-backed implementation touches nothing outside this file.
public final class MockSensorService: SensorService {
    private let fakeSensor = DiscoveredSensor(id: "MOCK-FLASH-0001", name: "Movesense Flash (simulé)", rssi: -45)

    /// One continuation per observer — see the note in MovesenseSensorService:
    /// a single shared stream only ever feeds its first consumer.
    private var connectionContinuations: [UUID: AsyncStream<SensorConnectionState>.Continuation] = [:]
    private let continuationsLock = NSLock()

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

    private var state: SensorConnectionState = .disconnected {
        didSet {
            continuationsLock.lock()
            let observers = connectionContinuations.values
            continuationsLock.unlock()
            for continuation in observers { continuation.yield(state) }
        }
    }

    private var loggingStartedAt: Date?
    private var storedEntries: [LogbookEntryInfo] = []
    private var entryData: [String: RawSessionData] = [:]

    public init() {}

    // MARK: - Connectivity

    public func scan() -> AsyncStream<DiscoveredSensor> {
        let sensor = fakeSensor
        return AsyncStream { continuation in
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                continuation.yield(sensor)
                continuation.finish()
            }
        }
    }

    public func stopScan() {}

    public func connect(to sensor: DiscoveredSensor) async throws {
        state = .connecting
        try await Task.sleep(nanoseconds: 600_000_000)
        state = .connected(sensor)
    }

    public func disconnect() async {
        state = .disconnecting
        try? await Task.sleep(nanoseconds: 200_000_000)
        state = .disconnected
    }

    // MARK: - Logbook

    public func startLogging(config: LoggingConfig) async throws {
        guard case .connected = state else { throw SensorError.notConnected }
        loggingStartedAt = Date()
    }

    public func isCurrentlyLogging() async throws -> Bool {
        guard case .connected = state else { throw SensorError.notConnected }
        return loggingStartedAt != nil
    }

    public func stopLogging() async throws {
        guard case .connected = state else { throw SensorError.notConnected }
        guard let start = loggingStartedAt else { return }
        let duration = Date().timeIntervalSince(start)
        try recordEntry(start: start, duration: max(duration, 60))
        loggingStartedAt = nil
    }

    public func listLogbookEntries() async throws -> [LogbookEntryInfo] {
        guard case .connected = state else { throw SensorError.notConnected }
        return storedEntries.sorted { $0.startDate > $1.startDate }
    }

    public func downloadEntry(_ entry: LogbookEntryInfo, progress: @escaping (Double) -> Void) async throws -> RawSessionData {
        guard case .connected = state else { throw SensorError.notConnected }
        guard let data = entryData[entry.id] else { throw SensorError.transferFailed("Entrée introuvable sur le capteur") }
        for step in 1...10 {
            try await Task.sleep(nanoseconds: 80_000_000)
            progress(Double(step) / 10)
        }
        return data
    }

    public func deleteEntry(_ entry: LogbookEntryInfo) async throws {
        storedEntries.removeAll { $0.id == entry.id }
        entryData.removeValue(forKey: entry.id)
    }

    public func eraseAllEntries() async throws {
        guard case .connected = state else { throw SensorError.notConnected }
        storedEntries.removeAll()
        entryData.removeAll()
    }

    // MARK: - Debug-only helper (not part of SensorService)

    /// Populates fake past sessions instantly, so History/Trends can be built and
    /// demoed without waiting real-time for enough session history to accumulate.
    public func seedFakeHistory(sessionCount: Int, spanDays: Int) {
        let calendar = Calendar.current
        for i in 0..<sessionCount {
            let daysAgo = Int.random(in: 0...max(spanDays, 1))
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let duration = Double.random(in: 25 * 60...75 * 60)
            try? recordEntry(start: date, duration: duration, idPrefix: "seed-\(i)-")
        }
    }

    /// Seeds a single session with amplified acceleration bursts, so it clearly
    /// dominates every rolling-window peak — a deterministic way to exercise the
    /// "nouveau record" UI without hunting for the actual argmax among random
    /// demo sessions. Returns the created entry so the caller can import just it.
    @discardableResult
    public func seedRecordSession() -> LogbookEntryInfo {
        let duration = Double.random(in: 40 * 60...60 * 60)
        return (try? recordEntry(start: Date(), duration: duration, idPrefix: "record-", intensityMultiplier: 3.0))
            ?? LogbookEntryInfo(id: "record-failed", startDate: Date(), duration: duration, sizeBytes: nil)
    }

    @discardableResult
    private func recordEntry(start: Date, duration: TimeInterval, idPrefix: String = "", intensityMultiplier: Double = 1.0) throws -> LogbookEntryInfo {
        let entry = LogbookEntryInfo(id: "\(idPrefix)\(UUID().uuidString)", startDate: start, duration: duration, sizeBytes: nil)
        storedEntries.append(entry)
        entryData[entry.id] = SyntheticSessionGenerator.generate(startDate: start, duration: duration, intensityMultiplier: intensityMultiplier)
        return entry
    }
}
