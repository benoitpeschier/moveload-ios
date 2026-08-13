import Foundation

public struct HRSample: Sendable, Codable {
    public let timeOffset: TimeInterval
    public let bpm: Double

    public init(timeOffset: TimeInterval, bpm: Double) {
        self.timeOffset = timeOffset
        self.bpm = bpm
    }
}

/// Sensor download result, decoupled from the Movesense wire format —
/// the real SensorService implementation's only job is to produce this shape.
public struct RawSessionData: Sendable, Codable {
    public let startDate: Date
    public let accelSampleRateHz: Double
    public let accelX: [Double]
    public let hrSamples: [HRSample]

    public init(startDate: Date, accelSampleRateHz: Double, accelX: [Double], hrSamples: [HRSample]) {
        self.startDate = startDate
        self.accelSampleRateHz = accelSampleRateHz
        self.accelX = accelX
        self.hrSamples = hrSamples
    }

    public var duration: TimeInterval {
        Double(accelX.count) / accelSampleRateHz
    }
}
