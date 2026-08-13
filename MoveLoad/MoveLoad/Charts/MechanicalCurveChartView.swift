import SwiftUI
import Charts
import MoveLoadCore

struct MechanicalCurveChartView: View {
    let sessionCurve: [MechanicalWindow: Double?]
    let records: [MechanicalWindow: Double]

    private struct CurvePoint: Identifiable {
        let id = UUID()
        let window: MechanicalWindow
        let value: Double
        let series: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Courbe d'accélération").font(.headline)

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
                }
                .frame(height: 220)
            }
        }
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
