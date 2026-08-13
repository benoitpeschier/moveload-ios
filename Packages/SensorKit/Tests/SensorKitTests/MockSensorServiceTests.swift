import Testing
@testable import SensorKit
import MoveLoadCore

@Test func mockFullRecordingPipelineProducesDownloadableEntry() async throws {
    let sensor = MockSensorService()

    var discovered: DiscoveredSensor?
    for await found in sensor.scan() {
        discovered = found
    }
    let found = try #require(discovered)

    try await sensor.connect(to: found)
    try await sensor.startLogging(config: LoggingConfig())
    try? await Task.sleep(nanoseconds: 50_000_000)
    try await sensor.stopLogging()

    let entries = try await sensor.listLogbookEntries()
    #expect(entries.count == 1)

    let data = try await sensor.downloadEntry(entries[0]) { _ in }
    #expect(!data.accelX.isEmpty)
    #expect(!data.hrSamples.isEmpty)

    await sensor.disconnect()
}

@Test func operationsWithoutConnectionThrow() async {
    let sensor = MockSensorService()
    await #expect(throws: SensorError.self) {
        try await sensor.startLogging(config: LoggingConfig())
    }
}

@Test func seedFakeHistoryPopulatesMultipleEntries() async throws {
    let sensor = MockSensorService()
    sensor.seedFakeHistory(sessionCount: 5, spanDays: 30)

    var discovered: DiscoveredSensor?
    for await found in sensor.scan() { discovered = found }
    try await sensor.connect(to: try #require(discovered))

    let entries = try await sensor.listLogbookEntries()
    #expect(entries.count == 5)
}
