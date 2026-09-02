import SwiftUI
import Charts
import MoveLoadCore

struct MechanicalCurveChartView: View {
    let sessionCurve: [MechanicalWindow: Double?]
    let records: [MechanicalWindow: Double]

    @State private var selectedLabel: String?

    private struct CurvePoint: Identifiable {
        let id = UUID()
        let window: MechanicalWindow
        let value: Double
        let series: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Courbe d'accélération").font(.headline)
                HelpButton(text: ChartHelp.accelerationCurve)
                Spacer()
            }

            // Its own line rather than the end of the title row: the readout
            // runs to "45 s · séance 1,03 · record 1,58", and beside the title
            // that width has to come from somewhere — SwiftUI took it from the
            // title, which wrapped the moment a point was touched. Reserved
            // even when nothing is selected, so the chart doesn't jump.
            Text(selectionSummary ?? " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if points.isEmpty {
                Text("Séance trop courte pour tracer la courbe").foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Durée", point.window.label),
                        y: .value("Accélération", point.value)
                    )
                    .foregroundStyle(by: .value("Série", point.series))
                    .symbol(by: .value("Série", point.series))

                    if let selectedLabel, selectedLabel == point.window.label {
                        RuleMark(x: .value("Durée", selectedLabel))
                            .foregroundStyle(.secondary.opacity(0.3))
                            .zIndex(-1)
                    }
                }
                .chartXSelection(value: $selectedLabel)
                .frame(height: 220)
            }
        }
    }

    /// The values behind the touched window, both series at once — reading a
    /// session against its own record is the point of this chart.
    private var selectionSummary: String? {
        guard let selectedLabel,
              let window = MechanicalWindow.allCases.first(where: { $0.label == selectedLabel })
        else { return nil }

        var parts: [String] = [selectedLabel]
        if let value = sessionCurve[window] ?? nil {
            parts.append(String(localized: "séance \(value.accelerationLabel)"))
        }
        if let record = records[window] {
            parts.append(String(localized: "record \(record.accelerationLabel)"))
        }
        return parts.joined(separator: " · ")
    }

    private var points: [CurvePoint] {
        var result: [CurvePoint] = []
        for window in MechanicalWindow.allCases {
            if let value = sessionCurve[window] ?? nil {
                result.append(CurvePoint(window: window, value: value, series: String(localized: "Séance")))
            }
            if let record = records[window] {
                result.append(CurvePoint(window: window, value: record, series: String(localized: "Record")))
            }
        }
        return result
    }
}
