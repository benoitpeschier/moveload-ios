import SwiftUI
import Charts

struct ZoneSlice: Identifiable {
    let id = UUID()
    let label: String
    let seconds: Double
    let color: Color
}

struct ZonePieChartView: View {
    let title: String
    let slices: [ZoneSlice]
    /// Shown instead of the chart when the zones have no meaning yet — a
    /// pie built on thresholds that don't exist reads as a real result.
    var unavailableMessage: String?
    var helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let helpText {
                    HelpButton(text: helpText)
                }
            }

            if let unavailableMessage {
                Text(unavailableMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if totalSeconds > 0 {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Temps", slice.seconds), innerRadius: .ratio(0.55))
                        .foregroundStyle(slice.color)
                        .cornerRadius(3)
                }
                .frame(height: 180)

                legend
            } else {
                Text("Pas de données").foregroundStyle(.secondary)
            }
        }
    }

    private var totalSeconds: Double {
        slices.reduce(0) { $0 + $1.seconds }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slices) { slice in
                HStack {
                    Circle().fill(slice.color).frame(width: 8, height: 8)
                    Text(slice.label)
                    Spacer()
                    Text(formatted(slice.seconds)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private func formatted(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
