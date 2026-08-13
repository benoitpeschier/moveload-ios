import Foundation

public enum HistoryCutoff {
    public static func cutoffDate(value: Int, unit: HistoryUnit, from reference: Date = .now) -> Date {
        let calendar = Calendar.current
        switch unit {
        case .days: return calendar.date(byAdding: .day, value: -value, to: reference) ?? reference
        case .weeks: return calendar.date(byAdding: .weekOfYear, value: -value, to: reference) ?? reference
        case .months: return calendar.date(byAdding: .month, value: -value, to: reference) ?? reference
        }
    }
}
