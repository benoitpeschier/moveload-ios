import Testing
@testable import AnalysisEngine
import MoveLoadCore

@Test func liveRecordsTakesMaxPerWindow() {
    let peaks: [RecordCalculator.HistoricalPeak] = [
        .init(window: .s3, value: 3.0),
        .init(window: .s3, value: 4.5),
        .init(window: .s45, value: 2.0),
    ]
    let records = RecordCalculator.liveRecords(from: peaks)
    #expect(records[.s3] == 4.5)
    #expect(records[.s45] == 2.0)
    #expect(records[.s6] == nil)
}
