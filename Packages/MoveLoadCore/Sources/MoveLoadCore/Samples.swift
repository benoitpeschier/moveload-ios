import Foundation

public struct HRSample: Sendable, Codable {
    public let timeOffset: TimeInterval
    public let bpm: Double

    public init(timeOffset: TimeInterval, bpm: Double) {
        self.timeOffset = timeOffset
        self.bpm = bpm
    }
}

/// All three accelerometer axes for a session. Load analysis only ever reads
/// one axis (see `RawSessionData.accelX`), but telling walking apart from
/// paddling needs the full vector: the discriminator is how much the trunk
/// bounces along gravity, and which axis gravity falls on depends on how the
/// sensor happens to be strapped on.
public struct AccelerationAxes: Sendable, Codable {
    public let x: [Double]
    public let y: [Double]
    public let z: [Double]

    public init(x: [Double], y: [Double], z: [Double]) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var count: Int { min(x.count, min(y.count, z.count)) }
}

/// Sensor download result, decoupled from the Movesense wire format —
/// the real SensorService implementation's only job is to produce this shape.
public struct RawSessionData: Sendable, Codable {
    public let startDate: Date
    public let accelSampleRateHz: Double
    /// The signal mechanical load is computed from: the sensor's Z axis on
    /// this chest mounting (verified 2026-08-06). The name is legacy — it
    /// predates knowing which physical axis carried the paddling signal.
    public let accelX: [Double]
    /// Present for real sensor downloads; nil for sources that only ever
    /// produced one axis (the simulated sensor, and sessions imported before
    /// triaxial storage existed). Gait exclusion is skipped when it's nil
    /// rather than guessed at from a single axis.
    public let axes: AccelerationAxes?
    public let hrSamples: [HRSample]

    public init(
        startDate: Date,
        accelSampleRateHz: Double,
        accelX: [Double],
        axes: AccelerationAxes? = nil,
        hrSamples: [HRSample]
    ) {
        self.startDate = startDate
        self.accelSampleRateHz = accelSampleRateHz
        self.accelX = accelX
        self.axes = axes
        self.hrSamples = hrSamples
    }

    /// Builds from a full triaxial record, taking Z as the effort signal.
    public init(startDate: Date, accelSampleRateHz: Double, axes: AccelerationAxes, hrSamples: [HRSample]) {
        self.init(
            startDate: startDate,
            accelSampleRateHz: accelSampleRateHz,
            accelX: axes.z,
            axes: axes,
            hrSamples: hrSamples
        )
    }

    public var duration: TimeInterval {
        Double(accelX.count) / accelSampleRateHz
    }
}
