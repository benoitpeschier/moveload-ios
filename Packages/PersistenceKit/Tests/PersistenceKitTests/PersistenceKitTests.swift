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
}
