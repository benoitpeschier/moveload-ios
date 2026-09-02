import SwiftUI

/// A question mark beside a chart title, explaining what the chart shows.
///
/// A popover rather than an alert: an explanation is context, not an event
/// demanding acknowledgement, and it should appear beside what it describes.
struct HelpButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Explication")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            // The width has to be set *before* the padding, not after. The
            // other way round, the text wraps at 270 − 28 while the popover
            // is sized at 270, so it reserves too little height and clips the
            // last lines — invisibly, and only for text long enough to wrap
            // more than the shortest bubble.
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(width: 270, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                // Without this the popover becomes a full sheet on iPhone,
                // which is far too much ceremony for two sentences.
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The explanations themselves, kept together so their wording can be read and
/// revised as a set rather than hunted through the views.
///
/// These are plain `String`, not `Text`, so the compiler does not extract them
/// the way it extracts every `Text("…")` in a view — they need `String(localized:)`
/// to reach the catalogue at all. The French text is the key.
enum ChartHelp {
    static var cardioLoad: String {
        String(localized: "Temps passé dans chaque zone de fréquence cardiaque, d'après les seuils réglés dans Réglages. La marche et les moments sans effort ne sont pas comptés.")
    }

    /// Takes the thresholds rather than quoting them, because they are
    /// settings: a figure written into the sentence goes stale the first time
    /// the athlete changes one, and help that contradicts the screen is worse
    /// than none.
    static func mechanicalLoad(percentLow: Double, percentHigh: Double) -> String {
        let low = Int((percentLow * 100).rounded())
        let high = Int((percentHigh * 100).rounded())
        return String(localized: "Temps passé dans chaque zone d'intensité de pagaie. Cette charge est calculée à partir de l'accélération de ton buste — sa variation de vitesse d'un instant à l'autre — mesurée par le capteur, gravité retirée.")
            + "\n\n"
            + String(localized: "Les seuils valent \(low) % et \(high) % de ta référence 45 s confirmée, modifiables dans Réglages. Ils s'appliquent à une moyenne glissante de 15 secondes, bien plus basse que les pics qu'elle lisse — d'où des pourcentages bas.")
    }

    static var timeAboveAnchor: String {
        String(localized: "Temps passé à pagayer plus fort que ta référence 45 s confirmée. Compté seconde par seconde sur le signal brut : les zones lissent sur 15 secondes et ne peuvent pas voir un effort plus court, celui-ci si.")
    }

    static var accelerationCurve: String {
        String(localized: "Ton meilleur effort moyen sur chaque durée, de 3 secondes à 3 minutes. La courbe verte est ton record sur la période d'historique choisie dans Réglages.")
    }
}

/// Seconds above the athlete's anchor, beside the zone pies.
///
/// Its own card rather than a line inside the mechanical pie: it answers a
/// different question. The pie says how the load was spread, this says how
/// much of it was hard — and unlike the zones it is beholden to no window, so
/// a twenty-second burst counts in full.
struct TimeAboveAnchorView: View {
    let seconds: Double
    let anchor: Double
    let countedSeconds: Double

    private var share: Double {
        countedSeconds > 0 ? seconds / countedSeconds * 100 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Temps au-dessus de la référence")
                    .font(.headline)
                HelpButton(text: ChartHelp.timeAboveAnchor)
            }

            if anchor <= 0 {
                Text("Il faut d'abord confirmer une référence 45 s pour que cette mesure ait un sens.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatted(seconds))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Int(share.rounded())) % du temps compté")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // The bar is the share of counted time, so the number has a
                // size as well as a value.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemFill))
                        Capsule()
                            .fill(Color.purple)
                            .frame(width: geometry.size.width * min(1, share / 100))
                    }
                }
                .frame(height: 10)

                Text("au-dessus de \(anchor, format: .number.precision(.fractionLength(2))) m/s²")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatted(_ s: Double) -> String {
        let total = Int(s.rounded())
        return total >= 60
            ? String(localized: "\(total / 60) min \(String(format: "%02d", total % 60)) s")
            : String(localized: "\(total) s")
    }
}

/// Two decimals in the reader's own notation — 1,58 in French, 1.58 in English.
/// `String(format:)` is fixed to a dot whatever the locale, which was invisible
/// while the app only spoke French.
extension Double {
    var accelerationLabel: String {
        formatted(.number.precision(.fractionLength(2)))
    }
}
