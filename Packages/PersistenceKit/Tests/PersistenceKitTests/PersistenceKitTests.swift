import Testing
import SwiftData
import Foundation
@testable import PersistenceKit
import MoveLoadCore

@MainActor
private func makeInMemoryContext() throws -> ModelContext {
    let container = try PersistenceContainer.make(inMemory: true)
    return ModelContext(container)
}

@MainActor
@Test func fetchOrCreateSingleAthleteReturnsSameInstance() throws {
    let context = try makeInMemoryContext()
    let repo = AthleteRepository()
    let first = try repo.fetchOrCreateSingleAthlete(in: context)
    let second = try repo.fetchOrCreateSingleAthlete(in: context)
    #expect(first.id == second.id)
    #expect(first.settings != nil)
}

@MainActor
@Test func createSessionPersistsZonesAndCurvePoints() throws {
    let context = try makeInMemoryContext()
    let athlete = try AthleteRepository().fetchOrCreateSingleAthlete(in: context)

    var curve: [MechanicalWindow: Double?] = [:]
    for window in MechanicalWindow.allCases { curve[window] = window == .s45 ? 5.0 : nil }

    let analysis = SessionAnalysisResult(
        hrZoneSeconds: [.i1: 100, .i2: 50, .i3: 10],
        mechZoneSeconds: [.zone1: 80, .zone2: 60, .zone3: 20],
        curve: curve,
        mechZoneAnchorUsed: 4.0
    )
    let raw = RawSessionData(startDate: .now, accelSampleRateHz: 52, accelX: [0, 1, 2], hrSamples: [])

    let session = try SessionRepository().createSession(
        from: raw, analysis: analysis, athlete: athlete,
        logbookEntryID: "entry-1", rawSampleDirectory: "Sessions/x", in: context
    )

    #expect(session.hrZoneI1Seconds == 100)
    #expect(session.mechZone3Seconds == 20)
    #expect(session.curvePoints.count == MechanicalWindow.allCases.count)

    let all = try SessionRepository().allSessions(in: context)
    #expect(all.count == 1)
}

@MainActor
@Test func historicalPeaksExcludesSessionsBeforeCutoff() throws {
    let context = try makeInMemoryContext()
    let athlete = try AthleteRepository().fetchOrCreateSingleAthlete(in: context)
    let repo = SessionRepository()

    func makeAnalysis(peak: Double) -> SessionAnalysisResult {
        SessionAnalysisResult(
            hrZoneSeconds: [:], mechZoneSeconds: [:],
            curve: [.s45: peak], mechZoneAnchorUsed: 0
        )
    }

    let oldRaw = RawSessionData(startDate: Date(timeIntervalSinceNow: -200 * 86400), accelSampleRateHz: 52, accelX: [0], hrSamples: [])
    try repo.createSession(from: oldRaw, analysis: makeAnalysis(peak: 9.0), athlete: athlete, logbookEntryID: "old", rawSampleDirectory: "a", in: context)

    let recentRaw = RawSessionData(startDate: Date(timeIntervalSinceNow: -1 * 86400), accelSampleRateHz: 52, accelX: [0], hrSamples: [])
    try repo.createSession(from: recentRaw, analysis: makeAnalysis(peak: 3.0), athlete: athlete, logbookEntryID: "recent", rawSampleDirectory: "b", in: context)

    let cutoff = HistoryCutoff.cutoffDate(value: 90, unit: .days)
    let peaks = try repo.historicalPeaks(after: cutoff, in: context)

    #expect(peaks.count == 1)
    #expect(peaks.first?.value == 3.0)
}

@Test func rawSampleFileStoreRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = RawSessionData(
        startDate: .now,
        accelSampleRateHz: 52,
        accelX: [0.1, 1.5, 2.75, 0, -0.3],
        hrSamples: [HRSample(timeOffset: 0, bpm: 80), HRSample(timeOffset: 2, bpm: 145)]
    )

    try RawSampleFileStore.write(original, to: dir)
    let readBack = try RawSampleFileStore.read(startDate: original.startDate, from: dir)

    #expect(readBack.accelSampleRateHz == 52)
    #expect(readBack.accelX.count == original.accelX.count)
    for (a, b) in zip(readBack.accelX, original.accelX) {
        #expect(abs(a - b) < 0.001)
    }
    #expect(readBack.hrSamples.count == 2)
    #expect(readBack.hrSamples[1].bpm == 145)
    // No axes given, so none should be invented on the way back.
    #expect(readBack.axes == nil)
}

/// Recordings stay on the sensor after import and the recovery path re-walks
/// ids, so the same log reaches the importer more than once.
@Test func sessionLookupFindsAnAlreadyImportedRecording() throws {
    let container = try PersistenceContainer.make(inMemory: true)
    let context = ModelContext(container)
    let athlete = try AthleteRepository().fetchOrCreateSingleAthlete(in: context)
    let repository = SessionRepository()

    let raw = RawSessionData(
        startDate: .now, accelSampleRateHz: 10, accelX: [1, 2, 3], hrSamples: []
    )
    let analysis = SessionAnalysisResult(
        hrZoneSeconds: [:], mechZoneSeconds: [:], curve: [:], mechZoneAnchorUsed: 0
    )
    _ = try repository.createSession(
        from: raw, analysis: analysis, athlete: athlete,
        logbookEntryID: "7", rawSampleDirectory: "dir", in: context
    )

    #expect(try repository.session(withLogbookEntryID: "7", in: context) != nil)
    #expect(try repository.session(withLogbookEntryID: "8", in: context) == nil)
    // An empty id belongs to no recording and must never match.
    #expect(try repository.session(withLogbookEntryID: "", in: context) == nil)
}

@Test func rawSampleFileStoreRoundTripsAllThreeAxes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let axes = AccelerationAxes(
        x: [0.1, -1.2, 3.4, 0.0],
        y: [9.8, 9.7, 10.1, 9.9],
        z: [1.0, -0.5, 2.2, 0.3]
    )
    let original = RawSessionData(
        startDate: .now,
        accelSampleRateHz: 52,
        axes: axes,
        hrSamples: [HRSample(timeOffset: 0, bpm: 80)]
    )

    try RawSampleFileStore.write(original, to: dir)
    let readBack = try RawSampleFileStore.read(startDate: original.startDate, from: dir)

    let restored = try #require(readBack.axes)
    for (a, b) in zip(restored.x, axes.x) { #expect(abs(a - b) < 0.001) }
    for (a, b) in zip(restored.y, axes.y) { #expect(abs(a - b) < 0.001) }
    for (a, b) in zip(restored.z, axes.z) { #expect(abs(a - b) < 0.001) }
    // Z stays the load signal, negative values intact for gravity projection.
    for (a, b) in zip(readBack.accelX, axes.z) { #expect(abs(a - b) < 0.001) }
    #expect(readBack.accelSampleRateHz == 52)
}

/// Sessions recorded before triaxial storage must keep opening — their files
/// have no magic header and start straight at the sample rate.
@Test func rawSampleFileStoreReadsLegacySingleAxisFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var legacy = Data()
    var rate = Float32(52)
    withUnsafeBytes(of: &rate) { legacy.append(contentsOf: $0) }
    for value in [Float32(0.5), 1.5, 2.5] {
        var v = value
        withUnsafeBytes(of: &v) { legacy.append(contentsOf: $0) }
    }
    try legacy.write(to: dir.appendingPathComponent("accel.bin"))

    let readBack = try RawSampleFileStore.read(startDate: .now, from: dir)

    #expect(readBack.accelSampleRateHz == 52)
    #expect(readBack.accelX.count == 3)
    #expect(abs(readBack.accelX[2] - 2.5) < 0.001)
    // Nothing to detect gait from — analysis must fall back to the whole session.
    #expect(readBack.axes == nil)
}
