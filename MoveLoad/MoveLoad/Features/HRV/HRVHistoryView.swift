import SwiftUI
import SwiftData
import AnalysisEngine
import Charts
import PersistenceKit

/// Past tests, and the trend across them.
///
/// A single morning's figures mean almost nothing — HRV is read against an
/// athlete's own history, not against a population. This is the view that makes
/// the daily ritual worth doing.
struct HRVHistoryView: View {
    @Query(sort: \HRVTest.date, order: .reverse) private var tests: [HRVTest]

    var body: some View {
        if tests.isEmpty {
            ContentUnavailableView(
                "Pas encore de test",
                systemImage: "heart.text.square",
                description: Text("Les tests du matin s'accumulent ici. C'est leur suite qui a du sens, pas un matin isolé.")
            )
        } else {
            VStack(alignment: .leading, spacing: 24) {
                trend
                list
            }
        }
    }

    // MARK: -

    private var points: [(date: Date, rmssd: Double, totalPower: Double, restingHR: Double)] {
        tests.reversed().compactMap { test in
            guard let supine = HeartRateVariability.analyse(
                rrIntervalsMs: test.supineRRms.map(Double.init)) else { return nil }
            return (test.date, supine.rmssdMs, supine.totalPower, supine.meanHRbpm)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allongé, au fil des tests").font(.headline)

            Chart(points, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value("rMSSD", point.rmssd))
                    .foregroundStyle(by: .value("Mesure", "rMSSD (ms)"))
                PointMark(x: .value("Date", point.date), y: .value("rMSSD", point.rmssd))
                    .foregroundStyle(by: .value("Mesure", "rMSSD (ms)"))

                LineMark(x: .value("Date", point.date), y: .value("FC", point.restingHR))
                    .foregroundStyle(by: .value("Mesure", "FC (bpm)"))
                PointMark(x: .value("Date", point.date), y: .value("FC", point.restingHR))
                    .foregroundStyle(by: .value("Mesure", "FC (bpm)"))
            }
            .frame(height: 180)

            // Total power is plotted apart and on a log scale: one 9452 against
            // a usual 700–1500 flattens every other point into the axis.
            Text("Puissance totale, échelle logarithmique").font(.subheadline)
            Chart(points, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value("ms²", max(point.totalPower, 1)))
                PointMark(x: .value("Date", point.date), y: .value("ms²", max(point.totalPower, 1)))
            }
            .chartYScale(type: .log)
            .frame(height: 140)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tests").font(.headline)
            ForEach(tests) { test in
                row(test)
                Divider()
            }
        }
    }

    private func row(_ test: HRVTest) -> some View {
        let supine = HeartRateVariability.analyse(rrIntervalsMs: test.supineRRms.map(Double.init))
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(test.date.formatted(date: .abbreviated, time: .shortened))
                if let score = test.wellnessScore {
                    Text("Wellness \(score) %").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let supine {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "rMSSD %.0f ms", supine.rmssdMs)).monospacedDigit()
                    Text(String(format: "%.0f bpm", supine.meanHRbpm))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }
}
