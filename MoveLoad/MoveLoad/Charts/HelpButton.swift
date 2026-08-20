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

    static let accelerationCurve = """
        Ton meilleur effort moyen sur chaque durée, de 3 secondes à 3 minutes. \
        La courbe verte est ton record sur la période d'historique choisie dans Réglages.
        """
}
