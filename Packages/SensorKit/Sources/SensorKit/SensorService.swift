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
}

/// The single boundary the Movesense SDK integration crosses. Everything else in
/// the app talks to this protocol; MockSensorService and (later) a real
/// CoreBluetooth/Movesense-SDK-backed implementation are the only conformers.
public protocol SensorService: SensorConnectivityService, SensorLogbookService {}
