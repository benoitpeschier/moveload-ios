import SwiftUI
import SwiftData
import PersistenceKit

/// Sessions laid out on a calendar, each day filled with the colours of the
/// mechanical zones in proportion to the time spent in each.
///
/// The fill is kept faint so the date stays readable on top of it; the point is
/// to recognise a month's shape at a glance, not to read exact values off it.
struct SessionCalendarView: View {
    let sessions: [Session]
    /// Morning tests, so a day can show both what was trained and how the
    /// athlete woke up. The two belong on the same square: the eye compares
    /// yesterday's load with this morning's reading without changing screen.
    @Query(sort: \HRVTest.date) private var hrvTests: [HRVTest]

    enum Span: String, CaseIterable {
        case month = "Mois"
        case week = "Semaine"

        var label: String {
            switch self {
            case .month: String(localized: "Mois")
            case .week: String(localized: "Semaine")
            }
        }
    }

    @State private var span: Span = .month
    @State private var anchorDate: Date = .now
    @State private var selectedDay: Date?

    private let calendar = Calendar.current
    private static let zoneOpacity: Double = 0.30

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
                    dayCell(day)
                }
            }

            // The month grid has no room for names — a column is about 45
            // points wide — so the selected day's sessions are listed under it.
            if span == .month, let selectedDay {
                selectedDayList(selectedDay)
            }
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
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let inPeriod = span == .week || calendar.isDate(day, equalTo: anchorDate, toGranularity: .month)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(inPeriod ? .primary : .secondary)
                if hasHRVTest(on: day) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.pink)
                }
            }

            ForEach(daySessions, id: \.id) { session in
                if span == .week {
                    // Only in week view: there the bar is 20 points tall and
                    // carries its name, so it is a real target. A month cell's
                    // 9-point sliver is far below a usable one — selecting the
                    // day and listing its sessions underneath is the way in.
                    NavigationLink(value: session.id) {
                        sessionBar(session, showName: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    sessionBar(session, showName: false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, minHeight: span == .month ? 52 : 104, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color(.separator), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // In week view the bars handle their own taps; a cell-wide gesture
            // would swallow them.
            if span == .month { selectedDay = day }
        }
    }

    private func sessionBar(_ session: Session, showName: Bool) -> some View {
        ZStack(alignment: .leading) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(zoneShares(session).enumerated()), id: \.offset) { index, share in
                        Rectangle()
                            .fill(zoneColor(index).opacity(Self.zoneOpacity))
                            .frame(width: geometry.size.width * share)
                    }
                }
            }
            if showName {
                Text(session.displayTitle)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
        }
        .frame(height: showName ? 20 : 9)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func selectedDayList(_ day: Date) -> some View {
        let daySessions = sessions(on: day)
        return VStack(alignment: .leading, spacing: 6) {
            Text(day.formatted(date: .complete, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)

            if daySessions.isEmpty {
                Text("Aucune séance").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(daySessions, id: \.id) { session in
                    NavigationLink(value: session.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayTitle).font(.subheadline)
                                Text("\(Int(session.duration / 60)) min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Data

    private func sessions(on day: Date) -> [Session] {
        sessions
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// The three zones as fractions of the session's zone time. A session with
    /// no zone time at all — no confirmed reference yet — gets an even split in
    /// grey rather than a misleading colour.
    private func zoneShares(_ session: Session) -> [Double] {
        let values = [session.mechZone1Seconds, session.mechZone2Seconds, session.mechZone3Seconds]
        let total = values.reduce(0, +)
        guard total > 0 else { return [1, 0, 0] }
        return values.map { $0 / total }
    }

    private func zoneColor(_ index: Int) -> Color {
        switch index {
        case 0: .green
        case 1: .yellow
        default: .purple
        }
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
            selectedDay = nil
        }
    }
}
