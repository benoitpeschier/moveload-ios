import SwiftUI
import Charts
import MoveLoadCore
import PersistenceKit

struct TrendsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var sessions: [Session] = []
    @State private var selectedWindow: MechanicalWindow = .s45
    @State private var records: [MechanicalWindow: Double] = [:]
    @State private var isSeeding = false
    @State private var isSeedingRecord = false
    @State private var selectedRecordDate: Date?
    @State private var selectedRPEDate: Date?

    var body: some View {
        List {
            Section("Progression des records") {
                Picker("Fenêtre", selection: $selectedWindow) {
                    ForEach(MechanicalWindow.allCases, id: \.self) { window in
                        Text(window.label).tag(window)
                    }
                }
                .pickerStyle(.segmented)

                if curvePoints.isEmpty {
                    Text("Pas encore assez de séances").foregroundStyle(.secondary)
                } else {
                    Chart(curvePoints) { point in
                        LineMark(x: .value("Date", point.date), y: .value("Pic", point.value))
                        PointMark(x: .value("Date", point.date), y: .value("Pic", point.value))

                        if let nearest = nearestCurvePoint, nearest.id == point.id {
                            RuleMark(x: .value("Date", nearest.date))
                                .foregroundStyle(.secondary.opacity(0.3))
                                .zIndex(-1)
                        }
                    }
                    .chartXAxis { dateAxisMarks }
                    .chartXSelection(value: $selectedRecordDate)
                    .frame(height: 200)

                    if let nearest = nearestCurvePoint {
                        Text("\(nearest.date.formatted(date: .abbreviated, time: .shortened)) : \(String(format: "%.2f", nearest.value)) m/s²")
                            .font(.caption.monospacedDigit())
                    } else if let record = records[selectedWindow] {
                        Text("Record actuel : \(String(format: "%.2f", record)) m/s²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Charge globale ressentie (RPE)") {
                if rpeTrendPoints.isEmpty {
                    Text("Pas encore de charge ressentie renseignée").foregroundStyle(.secondary)
                } else {
                    Chart(rpeTrendPoints) { point in
                        LineMark(x: .value("Date", point.date), y: .value("RPE", point.value))
                        PointMark(x: .value("Date", point.date), y: .value("RPE", point.value))

                        if let nearest = nearestRPEPoint, nearest.id == point.id {
                            RuleMark(x: .value("Date", nearest.date))
                                .foregroundStyle(.secondary.opacity(0.3))
                                .zIndex(-1)
                        }
                    }
                    .chartXAxis { dateAxisMarks }
                    .chartYScale(domain: 1...10)
                    .chartXSelection(value: $selectedRPEDate)
                    .frame(height: 200)

                    if let nearest = nearestRPEPoint {
                        Text("\(nearest.date.formatted(date: .abbreviated, time: .shortened)) : \(nearest.value) / 10")
                            .font(.caption.monospacedDigit())
                    }
                }
            }

            Section("Temps en zone cardio (toutes séances)") {
                if sessions.isEmpty {
                    Text("Pas encore de séance").foregroundStyle(.secondary)
                } else {
                    Chart(hrZoneTrendPoints) { point in
                        BarMark(x: .value("Date", point.date, unit: .day), y: .value("Secondes", point.seconds))
                            .foregroundStyle(by: .value("Zone", point.zoneLabel))
                            // Zones stack within a session; sessions sharing a
                            // day sit side by side rather than merging.
                            .position(by: .value("Séance", point.sessionID))
                    }
                    .chartXAxis { dateAxisMarks }
                    .chartForegroundStyleScale(["I1": Color.blue, "I2": Color.orange, "I3": Color.red])
                    .frame(height: 200)
                }
            }

            Section("Temps en zone mécanique (toutes séances)") {
                if sessions.isEmpty {
                    Text("Pas encore de séance").foregroundStyle(.secondary)
                } else {
                    Chart(mechZoneTrendPoints) { point in
                        BarMark(x: .value("Date", point.date, unit: .day), y: .value("Secondes", point.seconds))
                            .foregroundStyle(by: .value("Zone", point.zoneLabel))
                            .position(by: .value("Séance", point.sessionID))
                    }
                    .chartXAxis { dateAxisMarks }
                    .chartForegroundStyleScale(["Zone 1": Color.green, "Zone 2": Color.yellow, "Zone 3": Color.purple])
                    .frame(height: 200)
                }
            }

            Section {
                Button {
                    Task {
                        isSeeding = true
                        await appEnvironment.seedDemoHistoryIfPossible()
                        await reload()
                        isSeeding = false
                    }
                } label: {
                    if isSeeding {
                        ProgressView()
                    } else {
                        Text("Générer des séances fictives (démo)")
                    }
                }
                .disabled(isSeeding)

                Button {
                    Task {
                        isSeedingRecord = true
                        await appEnvironment.seedRecordSessionIfPossible()
                        await reload()
                        isSeedingRecord = false
                    }
                } label: {
                    if isSeedingRecord {
                        ProgressView()
                    } else {
                        Text("Générer une séance record évidente (démo)")
                    }
                }
                .disabled(isSeedingRecord)
            }
        }
        .navigationTitle("Tendances")
        .task { await reload() }
    }

    private struct CurveTrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    private struct RPETrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
    }

    private struct ZoneTrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let seconds: Double
        let zoneLabel: String
        /// Distinguishes sessions sharing a day, so two outings on the same
        /// date stand side by side instead of piling into one bar.
        let sessionID: String
    }

    /// Touch lands on an x position, not a data point, so the reading shown is
    /// the closest actual session — sessions are irregular in time and an
    /// interpolated value would be a number nobody recorded.
    private var nearestCurvePoint: CurveTrendPoint? {
        guard let selectedRecordDate else { return nil }
        return curvePoints.min {
            abs($0.date.timeIntervalSince(selectedRecordDate)) < abs($1.date.timeIntervalSince(selectedRecordDate))
        }
    }

    private var nearestRPEPoint: RPETrendPoint? {
        guard let selectedRPEDate else { return nil }
        return rpeTrendPoints.min {
            abs($0.date.timeIntervalSince(selectedRPEDate)) < abs($1.date.timeIntervalSince(selectedRPEDate))
        }
    }

    private var curvePoints: [CurveTrendPoint] {
        sessions
            .compactMap { session -> CurveTrendPoint? in
                guard let point = session.curvePoints.first(where: { $0.window == selectedWindow }),
                      let value = point.peakValue else { return nil }
                return CurveTrendPoint(date: session.startDate, value: value)
            }
            .sorted { $0.date < $1.date }
    }

    private var rpeTrendPoints: [RPETrendPoint] {
        sessions
            .compactMap { session -> RPETrendPoint? in
                guard let rpe = session.perceivedExertion else { return nil }
                return RPETrendPoint(date: session.startDate, value: rpe)
            }
            .sorted { $0.date < $1.date }
    }

    private var hrZoneTrendPoints: [ZoneTrendPoint] {
        sessions
            .flatMap { session in
                [
                    ZoneTrendPoint(date: session.startDate, seconds: session.hrZoneI1Seconds, zoneLabel: "I1", sessionID: session.id.uuidString),
                    ZoneTrendPoint(date: session.startDate, seconds: session.hrZoneI2Seconds, zoneLabel: "I2", sessionID: session.id.uuidString),
                    ZoneTrendPoint(date: session.startDate, seconds: session.hrZoneI3Seconds, zoneLabel: "I3", sessionID: session.id.uuidString),
                ]
            }
            .sorted { $0.date < $1.date }
    }

    private var mechZoneTrendPoints: [ZoneTrendPoint] {
        sessions
            .flatMap { session in
                [
                    ZoneTrendPoint(date: session.startDate, seconds: session.mechZone1Seconds, zoneLabel: "Zone 1", sessionID: session.id.uuidString),
                    ZoneTrendPoint(date: session.startDate, seconds: session.mechZone2Seconds, zoneLabel: "Zone 2", sessionID: session.id.uuidString),
                    ZoneTrendPoint(date: session.startDate, seconds: session.mechZone3Seconds, zoneLabel: "Zone 3", sessionID: session.id.uuidString),
                ]
            }
            .sorted { $0.date < $1.date }
    }

    /// Explicit "j mois" (ex. 31 juil.) date labels, spaced out to a handful of
    /// ticks — Swift Charts' default date axis crowds/duplicates labels once a
    /// chart has more than a few points, which read as noise rather than dates.
    private var dateAxisMarks: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisTick()
            if let date = value.as(Date.self) {
                AxisValueLabel(date.formatted(.dateTime.day().month(.abbreviated)))
            }
        }
    }

    private func reload() async {
        sessions = (try? appEnvironment.allSessions()) ?? []
        records = (try? appEnvironment.liveRecords()) ?? [:]
    }
}
