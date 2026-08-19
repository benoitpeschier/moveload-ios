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
/// A record-setting effort located in the recording, so the athlete can see
/// what their heart was doing while they were producing it.
struct RecordEffortSpan: Identifiable {
    let id = UUID()
    let label: String
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
}

struct HeartRateCurveChartView: View {
    let samples: [HRSample]
    let thresholdLow: Double
    let thresholdHigh: Double
    var recordEfforts: [RecordEffortSpan] = []

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
                    // Drawn first so the line stays legible on top. Short
                    // windows produce a very thin band, hence the minimum
                    // width — a 3 s effort in a 90 minute session would
                    // otherwise be invisible.
                    ForEach(effortBands) { band in
                        RectangleMark(
                            xStart: .value("Début", band.start / 60),
                            xEnd: .value("Fin", band.end / 60)
                        )
                        .foregroundStyle(.yellow.opacity(0.22))
                        .annotation(position: .top, alignment: .center, spacing: 0) {
                            Text(band.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

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

                if !recordEfforts.isEmpty {
                    HStack(spacing: 4) {
                        Rectangle().fill(.yellow.opacity(0.35)).frame(width: 10, height: 8)
                        Text("Record sur la séance : \(recordEfforts.map(\.label).joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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

    /// Enough of the axis for a band to be seen at all, scaled to the session
    /// so it stays proportionate on both a 5 minute test and a 2 hour outing.
    private var minimumVisibleSpanSeconds: TimeInterval {
        max((samples.last?.timeOffset ?? 0) * 0.012, 8)
    }

    private struct EffortBand: Identifiable {
        let id = UUID()
        let start: TimeInterval
        let end: TimeInterval
        let label: String
    }

    /// One band per effort, not per window. A single hard burst usually takes
    /// the record for every short window at once, which stacked six labels on
    /// the same spot and made all of them unreadable. Overlapping efforts are
    /// merged and labelled with the range they cover, which also says
    /// something true: these records all came from the same effort.
    private var effortBands: [EffortBand] {
        let spans = recordEfforts
            .map { effort -> (start: TimeInterval, end: TimeInterval, seconds: TimeInterval, label: String) in
                let width = max(effort.durationSeconds, minimumVisibleSpanSeconds)
                return (effort.startSeconds, effort.startSeconds + width, effort.durationSeconds, effort.label)
            }
            .sorted { $0.start < $1.start }
        guard !spans.isEmpty else { return [] }

        var bands: [EffortBand] = []
        var start = spans[0].start
        var end = spans[0].end
        var members = [(seconds: spans[0].seconds, label: spans[0].label)]

        func flush() {
            let sorted = members.sorted { $0.seconds < $1.seconds }
            let label = sorted.count == 1
                ? sorted[0].label
                : "\(sorted.first!.label)–\(sorted.last!.label)"
            bands.append(EffortBand(start: start, end: end, label: label))
        }

        for span in spans.dropFirst() {
            if span.start <= end {
                end = max(end, span.end)
                members.append((span.seconds, span.label))
            } else {
                flush()
                start = span.start
                end = span.end
                members = [(span.seconds, span.label)]
            }
        }
        flush()
        return bands
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
