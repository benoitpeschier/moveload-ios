import SwiftUI
import Charts
import MoveLoadCore

/// Heart rate over the session, drawn in the colour of the zone it is in at
/// each moment.
///
/// Swift Charts colours a whole series at once, so the line is cut into runs of
/// constant zone and each run drawn as its own series. Each run repeats its
/// predecessor's last sample, otherwise the colour changes would leave visible
/// gaps in the line.
struct HeartRateCurveChartView: View {
    let samples: [HRSample]
    let thresholdLow: Double
    let thresholdHigh: Double

    @State private var selectedOffset: TimeInterval?

    private struct Run: Identifiable {
        let id: Int
        let zone: HRZone
        let points: [HRSample]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fréquence cardiaque").font(.headline)
                Spacer()
                Text(selectionSummary ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if runs.isEmpty {
                Text("Pas de données cardio pour cette séance").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(runs) { run in
                        ForEach(run.points, id: \.timeOffset) { point in
                            LineMark(
                                x: .value("Temps", point.timeOffset / 60),
                                y: .value("FC", point.bpm),
                                series: .value("Segment", run.id)
                            )
                            .foregroundStyle(color(for: run.zone))
                        }
                    }

                    if let selected = nearestSample {
                        RuleMark(x: .value("Temps", selected.timeOffset / 60))
                            .foregroundStyle(.secondary.opacity(0.3))
                            .zIndex(-1)
                    }
                }
                .chartXSelection(value: $selectedOffset)
                .chartXAxisLabel("minutes")
                .frame(height: 200)

                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([HRZone.i1, .i2, .i3], id: \.self) { zone in
                HStack(spacing: 4) {
                    Circle().fill(color(for: zone)).frame(width: 8, height: 8)
                    Text(label(for: zone)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(for zone: HRZone) -> Color {
        switch zone {
        case .i1: .blue
        case .i2: .orange
        case .i3: .red
        }
    }

    private func label(for zone: HRZone) -> String {
        switch zone {
        case .i1: "I1"
        case .i2: "I2"
        case .i3: "I3"
        }
    }

    private func zone(for bpm: Double) -> HRZone {
        if bpm < thresholdLow { return .i1 }
        if bpm < thresholdHigh { return .i2 }
        return .i3
    }

    /// One point per ~4 s. A session carries a sample per heartbeat — many
    /// thousands — which Swift Charts would spend far more effort drawing than
    /// the eye can tell apart at this width.
    private var displaySamples: [HRSample] {
        guard let last = samples.last, last.timeOffset > 0 else { return samples }
        let targetCount = 400
        let step = max(1, samples.count / targetCount)
        guard step > 1 else { return samples }
        return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
    }

    private var runs: [Run] {
        let points = displaySamples
        guard !points.isEmpty else { return [] }

        var result: [Run] = []
        var current: [HRSample] = [points[0]]
        var currentZone = zone(for: points[0].bpm)

        for sample in points.dropFirst() {
            let sampleZone = zone(for: sample.bpm)
            if sampleZone == currentZone {
                current.append(sample)
            } else {
                // The boundary sample belongs to both runs, so the line stays
                // unbroken where the colour changes.
                current.append(sample)
                result.append(Run(id: result.count, zone: currentZone, points: current))
                current = [sample]
                currentZone = sampleZone
            }
        }
        result.append(Run(id: result.count, zone: currentZone, points: current))
        return result
    }

    private var nearestSample: HRSample? {
        guard let selectedOffset else { return nil }
        let target = selectedOffset * 60
        return displaySamples.min {
            abs($0.timeOffset - target) < abs($1.timeOffset - target)
        }
    }

    private var selectionSummary: String? {
        guard let sample = nearestSample else { return nil }
        let minutes = Int(sample.timeOffset / 60)
        let seconds = Int(sample.timeOffset.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d · %.0f bpm · %@", minutes, seconds, sample.bpm, label(for: zone(for: sample.bpm)))
    }
}
