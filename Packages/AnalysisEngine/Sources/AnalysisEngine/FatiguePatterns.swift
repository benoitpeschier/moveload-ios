import Foundation

/// The coach's fatigue-pattern rules, from Laurent Schmidt et al., reproduced
/// unchanged from the workbook they came in.
///
/// Read as a **cascade**: the first matching pattern wins and the rest are not
/// consulted. That is how the workbook evaluates them, and the order encodes
/// which reading takes precedence when two would fire — so it must not be
/// reordered for tidiness.
///
/// Everything is expressed as a **percentage change against a reference test**,
/// never as an absolute: these bands describe how an athlete has moved from
/// their own baseline, and the same LF in millisecondes carrées means opposite
/// things in two people.
public enum FatiguePatterns {

    /// The five patterns, in cascade order.
    public enum Pattern: String, Sendable, CaseIterable {
        case energyCollapse       = "F(HF-LF-)SU_ST"
        case acuteStress          = "F(LF+SU LF-ST)"
        case activationBrake      = "F(HF-SU HF+ST)"
        case extremeFatigue       = "F(HF+SU)"
        case peripheralRegulation = "F(LF-st)"

        /// The short name, without the physiological half.
        ///
        /// The athlete's screen shows this and nothing more: "hypotonie para et
        /// orthosympathique couché" is a sentence for the person who can weigh
        /// it, and half-understood it invites a training decision nobody should
        /// take from a phone.
        public var name: String {
            switch self {
            case .energyCollapse:       String(localized: "Effondrement de l'énergie", bundle: .module)
            case .acuteStress:          String(localized: "Stress aigu", bundle: .module)
            case .activationBrake:      String(localized: "Frein à l'activation", bundle: .module)
            case .extremeFatigue:       String(localized: "Fatigue extrême", bundle: .module)
            case .peripheralRegulation: String(localized: "Trouble de régulation de la pression périphérique", bundle: .module)
            }
        }

        /// What the pattern says about the athlete — **a description, never a
        /// prescription.** What session to do depends on the week's plan, the
        /// water and how the athlete feels, none of which this knows.
        public var reading: String {
            switch self {
            case .energyCollapse:
                String(localized: "Effondrement de l'énergie — hypotonie para et orthosympathique couché", bundle: .module)
            case .acuteStress:
                String(localized: "Stress aigu — hypertonie orthosympathique couché", bundle: .module)
            case .activationBrake:
                String(localized: "Frein à l'activation — hypertonie parasympathique debout", bundle: .module)
            case .extremeFatigue:
                String(localized: "Fatigue extrême — hypertonie parasympathique couché", bundle: .module)
            case .peripheralRegulation:
                String(localized: "Trouble de régulation de la pression périphérique — hypotonie orthosympathique debout", bundle: .module)
            }
        }
    }

    /// The thresholds, as percentages. Settings rather than constants: they are
    /// one author's calibration, and a squad may need to move them without a
    /// rebuild. Defaults are the workbook's values, unchanged.
    public struct Thresholds: Sendable, Equatable {
        public var energyCollapseHFSupine: Double = -48
        public var energyCollapseLFStanding: Double = -30
        public var acuteStressLFSupine: Double = 80
        public var acuteStressLFStanding: Double = -70
        public var activationBrakeHFSupine: Double = -50
        public var activationBrakeHFStanding: Double = 200
        public var extremeFatigueHFSupine: Double = 500
        public var peripheralRegulationLFStanding: Double = -80

        /// Below this, in ms², a reference power is too small for a percentage
        /// change to mean much: 16 → 146 ms² is +807 %, which looks alarming and
        /// is mostly arithmetic. Matches are still reported, flagged.
        public var smallBasePower: Double = 50

        public init() {}
    }

    /// Percentage changes against the reference, one per measure the rules use.
    public struct Deltas: Sendable, Equatable {
        public let hfSupine: Double
        public let lfSupine: Double
        public let hfStanding: Double
        public let lfStanding: Double
        /// True when any reference power the rules lean on was small enough that
        /// its percentage is arithmetic rather than physiology.
        public let restsOnSmallBase: Bool

        public init(hfSupine: Double, lfSupine: Double, hfStanding: Double,
                    lfStanding: Double, restsOnSmallBase: Bool) {
            self.hfSupine = hfSupine
            self.lfSupine = lfSupine
            self.hfStanding = hfStanding
            self.lfStanding = lfStanding
            self.restsOnSmallBase = restsOnSmallBase
        }
    }

    /// One position's spectral powers, in ms².
    public struct Powers: Sendable, Equatable {
        public let lf: Double
        public let hf: Double
        public init(lf: Double, hf: Double) {
            self.lf = lf
            self.hf = hf
        }
    }

    /// Percentage change from `reference` to `current`.
    ///
    /// A reference of zero has no percentage — returning a huge number there
    /// would fire the +500 % rule on the first test after a failed one.
    public static func percentChange(from reference: Double, to current: Double) -> Double? {
        guard reference > 0 else { return nil }
        return (current - reference) / reference * 100
    }

    public static func deltas(
        currentSupine: Powers, currentStanding: Powers,
        referenceSupine: Powers, referenceStanding: Powers,
        thresholds: Thresholds = Thresholds()
    ) -> Deltas? {
        guard let hfSu = percentChange(from: referenceSupine.hf, to: currentSupine.hf),
              let lfSu = percentChange(from: referenceSupine.lf, to: currentSupine.lf),
              let hfSt = percentChange(from: referenceStanding.hf, to: currentStanding.hf),
              let lfSt = percentChange(from: referenceStanding.lf, to: currentStanding.lf)
        else { return nil }

        let smallest = min(referenceSupine.hf, referenceSupine.lf,
                           referenceStanding.hf, referenceStanding.lf)
        return Deltas(hfSupine: hfSu, lfSupine: lfSu, hfStanding: hfSt, lfStanding: lfSt,
                      restsOnSmallBase: smallest < thresholds.smallBasePower)
    }

    /// The cascade. Returns nil for "pas de fatigue" — the absence of a pattern,
    /// not a pattern of its own.
    public static func evaluate(_ d: Deltas, thresholds: Thresholds = Thresholds()) -> Pattern? {
        if d.hfSupine < thresholds.energyCollapseHFSupine,
           d.lfStanding < thresholds.energyCollapseLFStanding {
            return .energyCollapse
        }
        if d.lfSupine > thresholds.acuteStressLFSupine,
           d.lfStanding < thresholds.acuteStressLFStanding {
            return .acuteStress
        }
        if d.hfSupine < thresholds.activationBrakeHFSupine,
           d.hfStanding > thresholds.activationBrakeHFStanding {
            return .activationBrake
        }
        if d.hfSupine > thresholds.extremeFatigueHFSupine {
            return .extremeFatigue
        }
        if d.lfStanding < thresholds.peripheralRegulationLFStanding {
            return .peripheralRegulation
        }
        return nil
    }
}
