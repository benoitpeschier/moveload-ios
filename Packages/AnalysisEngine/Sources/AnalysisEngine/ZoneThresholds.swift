import Foundation

public enum ZoneThresholds {
    public static func mechanical(anchor: Double, percentLow: Double, percentHigh: Double) -> (low: Double, high: Double) {
        (anchor * percentLow, anchor * percentHigh)
    }
}
