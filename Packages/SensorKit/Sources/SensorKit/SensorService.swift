import Foundation
import MoveLoadCore

public protocol SensorConnectivityService: AnyObject {
    func scan() -> AsyncStream<DiscoveredSensor>
    func stopScan()
    func connect(to sensor: DiscoveredSensor) async throws
    func disconnect() async
    var connectionState: AsyncStream<SensorConnectionState> { get }
}

public protocol SensorLogbookService: AnyObject {
    func startLogging(config: LoggingConfig) async throws
    func stopLogging() async throws
    func listLogbookEntries() async throws -> [LogbookEntryInfo]
    func downloadEntry(_ entry: LogbookEntryInfo, progress: @escaping (Double) -> Void) async throws -> RawSessionData
    func deleteEntry(_ entry: LogbookEntryInfo) async throws

    /// Erases the sensor's entire logbook at once. Some backends (the real
    /// Movesense GSP protocol) have no way to delete a single entry — this
    /// is the only deletion primitive available, so callers must warn about
    /// any entries not yet downloaded before calling it.
    func eraseAllEntries() async throws
}

/// The single boundary the Movesense SDK integration crosses. Everything else in
/// the app talks to this protocol; MockSensorService and (later) a real
/// CoreBluetooth/Movesense-SDK-backed implementation are the only conformers.
public protocol SensorService: SensorConnectivityService, SensorLogbookService {}
