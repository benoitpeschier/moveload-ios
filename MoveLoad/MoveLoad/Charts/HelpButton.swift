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
            // A definite width, not a maximum: without one the popover cannot
            // work out where the text wraps, so it measures its own height
            // wrongly and clips the last lines.
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 270)
                // Without this the popover becomes a full sheet on iPhone,
                // which is far too much ceremony for two sentences.
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// The explanations themselves, kept together so their wording can be read and
/// revised as a set rather than hunted through the views.
enum ChartHelp {
    static let cardioLoad = """
        Temps passé dans chaque zone de fréquence cardiaque, d'après les seuils \
        réglés dans Réglages. La marche et les moments sans effort ne sont pas comptés.
        """

    static let mechanicalLoad = """
        Temps passé dans chaque zone d'intensité de pagaie. Les seuils valent 70 % \
        et 90 % de ta référence 45 s confirmée — des pourcentages modifiables dans \
        Réglages. Cette charge est calculée à partir de l'accélération de ton buste \
        — sa variation de vitesse d'un instant à l'autre — mesurée par le capteur, \
        gravité retirée.
        """

    static let timeAboveAnchor = """
        Temps passé à pagayer plus fort que ta référence 45 s confirmée. \
        Compté seconde par seconde sur le signal brut : les zones lissent sur \
        15 secondes et ne peuvent pas voir un effort plus court, celui-ci si.
        """

    static let accelerationCurve = """
        Ton meilleur effort moyen sur chaque durée, de 3 secondes à 3 minutes. \
        La courbe verte est ton record sur la période d'historique choisie dans Réglages.
        """
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
        return total >= 60 ? "\(total / 60) min \(String(format: "%02d", total % 60)) s" : "\(total) s"
    }
}
