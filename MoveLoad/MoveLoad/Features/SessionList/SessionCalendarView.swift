import SwiftUI
import SwiftData
import PersistenceKit

/// Sessions laid out on a calendar, each day filled with the colours of the
/// mechanical zones in proportion to the time spent in each.
///
/// The fill is kept faint so the date stays readable on top of it; the point is
/// to recognise a week's shape at a glance, not to read exact values off it.
struct SessionCalendarView: View {
    let sessions: [Session]
    /// Morning tests, so a day can show both what was trained and how the
    /// athlete woke up. The two belong on the same square: the eye compares
    /// yesterday's load with this morning's reading without changing screen.
    @Query(sort: \HRVTest.date) private var hrvTests: [HRVTest]

    /// Week first, and the default: the training week is the unit an athlete
    /// plans and reads in. The month is the step back taken afterwards, and
    /// opening on it meant a screen where no session carried its name.
    enum Span: String, CaseIterable {
        case week = "Semaine"
        case month = "Mois"

        var label: String {
            switch self {
            case .week: String(localized: "Semaine")
            case .month: String(localized: "Mois")
            }
        }
    }

    @State private var span: Span = .week
    @State private var anchorDate: Date = .now

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 12) {
            header

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(displayedDays, id: \.self) { day in
                    // The whole square, rather than the bars inside it: a
                    // month cell's 9-point sliver is far below a usable tap
                    // target, and one target per day behaves the same in both
                    // spans instead of changing under the finger.
                    NavigationLink(value: CalendarDay(date: day)) {
                        dayCell(day)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Touche un jour pour l'ouvrir.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("Période", selection: $span) {
                ForEach(Span.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(periodLabel).font(.headline)
                Spacer()
                Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.plain)
        }
    }

    private func hasHRVTest(on day: Date) -> Bool {
        hrvTests.contains { calendar.isDate($0.date, inSameDayAs: day) }
    }

    private func dayCell(_ day: Date) -> some View {
        let daySessions = sessions(on: day)
        let isToday = calendar.isDateInToday(day)
        let inPeriod = span == .week || calendar.isDate(day, equalTo: anchorDate, toGranularity: .month)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(inPeriod ? .primary : .secondary)
                if hasHRVTest(on: day) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.pink)
                }
            }

            ForEach(daySessions, id: \.id) { session in
                // Only the week's bars are tall enough to carry a name.
                SessionZoneBar(session: session, showsName: span == .week)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, minHeight: span == .month ? 52 : 104, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isToday ? Color.accentColor : Color(.separator), lineWidth: isToday ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Data

    private func sessions(on day: Date) -> [Session] {
        sessions
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Dates

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var displayedDays: [Date] {
        switch span {
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return [] }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        case .month:
            guard let monthInterval = calendar.dateInterval(of: .month, for: anchorDate),
                  let gridStart = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)?.start
            else { return [] }
            // Whole weeks, so the grid never has ragged edges.
            let dayCount = calendar.dateComponents([.day], from: gridStart, to: monthInterval.end).day ?? 28
            let cellCount = Int((Double(dayCount) / 7).rounded(.up)) * 7
            return (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
        }
    }

    private var periodLabel: String {
        switch span {
        case .month:
            return anchorDate.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchorDate) else { return "" }
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private func shift(by amount: Int) {
        let component: Calendar.Component = span == .month ? .month : .weekOfYear
        if let moved = calendar.date(byAdding: component, value: amount, to: anchorDate) {
            anchorDate = moved
        }
    }
}

/// One session's zone time as a single stacked bar.
///
/// Shared by the calendar squares and the day view so the same session keeps
/// the same stripe wherever it is shown.
struct SessionZoneBar: View {
    let session: Session
    var showsName: Bool = false
    var height: CGFloat = 9

    private static let zoneOpacity: Double = 0.30

    /// A PPG session carries no mechanical figures at all — the app does not
    /// produce them, because chest acceleration while running is stride. Where
    /// a mechanical bar would go, show the cardiac one.
    ///
    /// Nil when there is no zone time to show: without a confirmed 45 s
    /// reference the mechanical zones are all zero, and painting that as a
    /// full zone 1 bar reads as a whole session spent easy rather than as a
    /// setting that has never been made.
    private var zones: (seconds: [Double], colours: [Color])? {
        let seconds = session.isConditioning
            ? [session.hrZoneI1Seconds, session.hrZoneI2Seconds, session.hrZoneI3Seconds]
            : [session.mechZone1Seconds, session.mechZone2Seconds, session.mechZone3Seconds]
        guard seconds.reduce(0, +) > 0 else { return nil }
        return (seconds, session.isConditioning ? [.blue, .orange, .red] : [.green, .yellow, .purple])
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geometry in
                if let zones {
                    let total = zones.seconds.reduce(0, +)
                    HStack(spacing: 0) {
                        ForEach(Array(zones.seconds.enumerated()), id: \.offset) { index, value in
                            Rectangle()
                                .fill(zones.colours[index].opacity(Self.zoneOpacity))
                                .frame(width: geometry.size.width * value / total)
                        }
                    }
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.18))
                }
            }
            if showsName {
                Text(session.displayTitle)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
        }
        .frame(height: showsName ? 20 : height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
