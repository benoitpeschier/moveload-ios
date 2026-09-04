import SwiftUI
import SwiftData
import AnalysisEngine
import PersistenceKit

/// One day of the calendar, as a navigation value.
struct CalendarDay: Hashable {
    let date: Date
}

/// A single day, read the way a training day is lived: how the morning went,
/// then what was done with it.
///
/// The calendar square can only hold a stripe and a number. This is where the
/// day becomes legible — and where a session is opened from, in the month span
/// where the stripes are far too small to aim at.
struct SessionDayView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    let day: Date
    /// Every session, filtered here: the calendar already holds them all, and
    /// re-reading the store for one day would only be another chance for the
    /// two screens to disagree.
    let sessions: [Session]

    @Query(sort: \HRVTest.date) private var hrvTests: [HRVTest]

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let test = morningTest {
                    hrvSection(test)
                }
                sessionsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sessions

    private var daySessions: [Session] {
        sessions
            .filter { calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Séances").font(.headline)
                Spacer()
                if !daySessions.isEmpty {
                    let minutes = Int(daySessions.reduce(0) { $0 + $1.duration } / 60)
                    Text("Total \(minutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if daySessions.isEmpty {
                Text("Aucune séance ce jour-là.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(daySessions, id: \.id) { session in
                    NavigationLink(value: session.id) {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.subheadline).fontWeight(.medium)
                    Text(subtitle(session)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            SessionZoneBar(session: session, height: 10)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func subtitle(_ session: Session) -> String {
        var parts = [
            session.startDate.formatted(date: .omitted, time: .shortened),
            String(localized: "\(Int(session.duration / 60)) min"),
        ]
        if session.isConditioning { parts.append(String(localized: "PPG")) }
        if let rpe = session.perceivedExertion { parts.append(String(localized: "RPE \(rpe)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Morning test

    /// The last test of the day, on the rare morning with two.
    private var morningTest: HRVTest? {
        hrvTests.last { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Read against the tests that came before it, not against the whole
    /// series: a day in June must show what it showed in June, not what it
    /// would show against three months of later mornings.
    private var outcome: HRVVerdict.Outcome? {
        guard let test = morningTest,
              let settings = appEnvironment.athlete.settings else { return nil }
        return HRVVerdict.evaluate(
            current: test,
            earlier: hrvTests.filter { $0.date < test.date },
            settings: settings)
    }

    private func hrvSection(_ test: HRVTest) -> some View {
        let supine = HeartRateVariability.analyse(rrIntervalsMs: test.supineRRms.map(Double.init))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Test du matin").font(.headline)
                Spacer()
                Text(test.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 24) {
                if let supine {
                    metric("rMSSD", String(format: "%.0f ms", supine.rmssdMs))
                    metric(String(localized: "FC"), String(format: "%.0f bpm", supine.meanHRbpm))
                }
                if let score = test.wellnessScore {
                    metric("Wellness", "\(score) %")
                }
            }

            if let outcome {
                HStack(spacing: 8) {
                    Circle()
                        .fill(outcome.pattern?.colour ?? FatigueBalance.colour)
                        .frame(width: 10, height: 10)
                    Text(outcome.pattern?.name ?? FatigueBalance.name)
                        .font(.callout).fontWeight(.medium)
                }
                // Never a name on its own: the reading is a marker, and the
                // training decision it invites is not the athlete's to take
                // from a phone screen.
                Text("À faire valider par ton coach : c'est un repère, pas un diagnostic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Il faut au moins deux tests pour situer le matin par rapport aux précédents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}
