import Foundation
import SwiftData

public struct AthleteRepository {
    public init() {}

    /// V1 is single-athlete: creates the one Athlete (with default settings) on
    /// first launch and always returns that same instance afterward.
    public func fetchOrCreateSingleAthlete(in context: ModelContext) throws -> Athlete {
        let descriptor = FetchDescriptor<Athlete>()
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let athlete = Athlete()
        let settings = AthleteSettings()
        athlete.settings = settings
        context.insert(athlete)
        try context.save()
        return athlete
    }
}
