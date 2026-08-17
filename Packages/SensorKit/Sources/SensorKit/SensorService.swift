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

    /// Whether the sensor is recording right now, read from the device rather
    /// than assumed. Recording continues without the phone, so an app that
    /// only tracked its own start/stop calls would show the wrong button
    /// after a relaunch or a reconnection from another phone.
    func isCurrentlyLogging() async throws -> Bool

    /// Whether the sensor's storage is full enough that it has stopped
    /// recording. Nil when the backend can't tell.
    func isStorageFull() async throws -> Bool?
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
