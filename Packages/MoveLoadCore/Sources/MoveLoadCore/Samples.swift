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


/// One live heart-rate notification from the sensor.
///
/// The layout was read off the wire on 2026-09-01 rather than assumed: a
/// notification is `float32` little-endian (the averaged bpm) followed by one
/// or more `uint16` little-endian R-R intervals in milliseconds. Captured
/// samples decoded to 46.6–48.8 bpm average against 1218–1453 ms intervals,
/// which agree — mean R-R 1294 ms is 46.3 bpm.
///
/// `rrIntervalsMs` is what HRV is computed from; `bpm` is the sensor's own
/// smoothed figure and is only good for showing a number on screen.
public struct HeartRateStreamSample: Sendable, Equatable {
    public let bpm: Double
    public let rrIntervalsMs: [Int]

    public init(bpm: Double, rrIntervalsMs: [Int]) {
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
    }

    /// Returns nil for a payload too short to hold the average, rather than
    /// inventing a beat from whatever bytes arrived.
    public init?(payload: Data) {
        guard payload.count >= 4 else { return nil }
        let bytes = [UInt8](payload)
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        self.bpm = Double(Float(bitPattern: raw))

        // The whiteboard type carries rrData as an array, so a notification may
        // hold more than one beat even though every sample observed so far held
        // exactly one. Reading however many fit costs nothing and avoids
        // silently dropping beats the day the sensor batches them.
        var intervals: [Int] = []
        var index = 4
        while index + 1 < bytes.count {
            intervals.append(Int(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        self.rrIntervalsMs = intervals
    }
}
