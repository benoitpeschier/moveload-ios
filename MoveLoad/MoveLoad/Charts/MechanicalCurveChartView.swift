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
            HStack {
                Text("Courbe d'accélération").font(.headline)
                Spacer()
                // Reserve the row even when nothing is selected, so the chart
                // doesn't jump as values appear and disappear.
                Text(selectionSummary ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

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
            parts.append(String(format: "séance %.2f", value))
        }
        if let record = records[window] {
            parts.append(String(format: "record %.2f", record))
        }
        return parts.joined(separator: " · ")
    }

    private var points: [CurvePoint] {
        var result: [CurvePoint] = []
        for window in MechanicalWindow.allCases {
            if let value = sessionCurve[window] ?? nil {
                result.append(CurvePoint(window: window, value: value, series: "Séance"))
            }
            if let record = records[window] {
                result.append(CurvePoint(window: window, value: record, series: "Record"))
            }
        }
        return result
    }
}
