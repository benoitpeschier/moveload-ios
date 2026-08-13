import Testing
@testable import MoveLoadCore
import Foundation

@Test func mechanicalWindowSecondsAreOrdered() {
    let seconds = MechanicalWindow.allCases.map(\.seconds)
    #expect(seconds == seconds.sorted())
    #expect(MechanicalWindow.anchorWindow == .s45)
}

@Test func rawSessionDataDurationMatchesSampleCount() {
    let data = RawSessionData(
        startDate: .now,
        accelSampleRateHz: 52,
        accelX: Array(repeating: 0.0, count: 520),
        hrSamples: []
    )
    #expect(data.duration == 10)
}
