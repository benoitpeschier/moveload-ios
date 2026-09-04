import AudioToolbox
import Foundation
import UIKit
import MoveLoadCore
import MovesenseVendor
import Observation

/// Runs one orthostatic test: five minutes lying, five standing, collecting
/// R-R intervals live from the sensor.
///
/// Separate from the view because the test is a ten-minute process with a
/// device attached — it has to survive the athlete putting the phone down, and
/// it is worth being able to reason about without SwiftUI in the way.
@Observable
@MainActor
final class HRVTestRecorder {

    enum Phase: Equatable {
        case idle
        case connecting
        /// Lying down. The athlete is told to stand when this ends.
        case supine
        case standing
        case finished
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var currentBpm: Double?
    private(set) var supineRR: [Int] = []
    private(set) var standingRR: [Int] = []
    /// Set once the link has actually been given back, so the screen can say so
    /// rather than announce a disconnection that is still in flight.
    private(set) var didDisconnect = false

    /// Five minutes a position. The analyser trims 30 s from each end, which is
    /// what leaves four clean minutes — see HeartRateVariability.
    static let positionSeconds: TimeInterval = 300

    private let sensor: MovesenseSensorService
    private var subscription: UInt8?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    /// The logger is stopped for the duration and put back as it was. Without
    /// this the auto-start firmware files a junk ten-minute session every
    /// single morning.
    private var loggerWasRunning = false

    init(sensor: MovesenseSensorService) {
        self.sensor = sensor
    }

    var secondsRemainingInPhase: TimeInterval {
        switch phase {
        case .supine: max(0, Self.positionSeconds - elapsed)
        case .standing: max(0, Self.positionSeconds * 2 - elapsed)
        default: 0
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .connecting
        supineRR = []
        standingRR = []
        elapsed = 0
        didDisconnect = false

        // Ten minutes lying still is exactly how long iOS waits before dimming
        // and locking, and a locked screen takes the timer and the position
        // change with it.
        UIApplication.shared.isIdleTimerDisabled = true

        loggerWasRunning = (try? await sensor.isCurrentlyLogging()) ?? false
        if loggerWasRunning { try? await sensor.stopLogging() }

        do {
            subscription = try await sensor.subscribeHeartRate { [weak self] sample in
                Task { @MainActor in self?.receive(sample) }
            }
        } catch {
            UIApplication.shared.isIdleTimerDisabled = false
            phase = .failed(error.localizedDescription)
            return
        }

        // The clock does not start until beats are actually arriving.
        //
        // Started on connection instead, the five minutes include however long
        // the heart rate takes to lock on — and the engine measures a position
        // by the sum of its intervals, not by the wall clock. On 2026-09-02 that
        // left the supine series just under the 210 s it needs after trimming,
        // and the spectrum was flagged unreliable for want of a few seconds.
        phase = .connecting
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self?.tick()
            }
        }
    }

    /// Sound *and* vibration, because the athlete is lying down with their eyes
    /// shut and the phone may well be on silent — and a change of position
    /// missed by a minute is a test worth redoing.
    private static func alert() {
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    func cancel() async {
        await finish(reaching: .idle)
    }

    private func tick() async {
        guard let startedAt, phase == .supine || phase == .standing else { return }
        elapsed = Date().timeIntervalSince(startedAt)

        if phase == .supine, elapsed >= Self.positionSeconds {
            phase = .standing
            Self.alert()
        } else if phase == .standing, elapsed >= Self.positionSeconds * 2 {
            Self.alert()
            await finish(reaching: .finished)
        }
    }

    private func receive(_ sample: HeartRateStreamSample) {
        currentBpm = sample.bpm

        // First beat through: the position begins now.
        if phase == .connecting, !sample.rrIntervalsMs.isEmpty {
            startedAt = Date()
            phase = .supine
        }

        // Intervals are filed against the phase they arrive in. A beat that
        // straddles the change of position belongs cleanly to neither, which is
        // exactly why the analyser trims 30 s from each end.
        switch phase {
        case .supine: supineRR.append(contentsOf: sample.rrIntervalsMs)
        case .standing: standingRR.append(contentsOf: sample.rrIntervalsMs)
        default: break
        }
    }

    private func finish(reaching newPhase: Phase) async {
        UIApplication.shared.isIdleTimerDisabled = false
        ticker?.cancel()
        ticker = nil
        if let subscription {
            await sensor.unsubscribeHeartRate(reference: subscription)
        }
        subscription = nil
        // Left as it was found: an athlete who was mid-session before the test
        // must not discover afterwards that nothing was being recorded.
        if loggerWasRunning {
            try? await sensor.startLogging(config: LoggingConfig())
        }
        phase = newPhase

        // Hang up. Nothing past this point needs the sensor: the intervals are
        // already in memory, and the questionnaire and the save are the phone's
        // business alone.
        //
        // Not merely tidiness. A connected sensor does not advertise, and the
        // firmware refuses to arm while a phone is on the line — deliberately,
        // since a connected phone means someone is using the sensor rather than
        // putting a strap on to train. So a link left open after the morning
        // test is a link that stops the session an hour later from recording
        // itself, and the athlete has no reason to suspect the two are related.
        //
        // Only on a finished test: a cancel is usually followed by another
        // attempt straight away, and hanging up would make the athlete
        // reconnect to make it.
        if newPhase == .finished {
            await sensor.disconnect()
            didDisconnect = true
        }
    }
}
