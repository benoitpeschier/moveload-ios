import Foundation
import SwiftData

public enum PersistenceContainer {
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([Athlete.self, AthleteSettings.self, Session.self, MechanicalCurvePoint.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func documentsSessionsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Sessions", isDirectory: true)
    }
}
