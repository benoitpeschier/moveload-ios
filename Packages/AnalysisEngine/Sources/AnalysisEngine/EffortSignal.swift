import Foundation

/// Turns the raw load axis into the part that reflects effort.
///
/// The accelerometer measures gravity as well as movement, so the raw axis
/// carries a slow component that depends only on how the sensor is tilted.
/// That made the load metric measure posture: on two real recordings
/// (2026-08-17) the "best 45 s effort" was the sensor lying still — vertical
/// standard deviation 0.4, total magnitude 9.90, i.e. gravity alone — scoring
/// 8.49 where actual paddling reached 1 to 3. Records went to whichever
/// session left the sensor resting in the most favourable orientation, and
/// peak curves came out nearly flat across every window, which no
/// physiological effort ever is.
///
/// Subtracting a short moving average removes gravity and posture while
/// leaving stroke dynamics intact. Two seconds is comfortably longer than a
/// paddle stroke (roughly 0.5 to 1 s) so strokes survive, and short enough
/// that a change of tilt is followed rather than mistaken for effort.
///
/// Note that gait detection deliberately does *not* use this: it needs
/// gravity, since that is how it finds which way is down.
public enum EffortSignal {
    public static let baselineSeconds: Double = 2.0

    public static func dynamic(_ signal: [Double], sampleRateHz: Double) -> [Double] {
        let count = signal.count
        guard count > 0, sampleRateHz > 0 else { return signal }
        let window = Int((baselineSeconds * sampleRateHz).rounded())
        guard window > 1, count > window else {
            // Too short to establish a baseline; centring on the mean is the
            // best available equivalent.
            let mean = signal.reduce(0, +) / Double(count)
            return signal.map { $0 - mean }
        }

        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + signal[i] }

        let half = window / 2
        return (0..<count).map { i in
            // Centred window, shrinking at the edges rather than padding —
            // padding would invent a baseline the recording never had.
            let lower = max(0, i - half)
            let upper = min(count, i + half + 1)
            let baseline = (prefix[upper] - prefix[lower]) / Double(upper - lower)
            return signal[i] - baseline
        }
    }
}
