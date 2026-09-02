import SwiftUI

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var appEnvironment

    var body: some View {
        if appEnvironment.athlete == nil {
            ProgressView()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                SessionListView()
            }
            .tabItem { Label("Séances", systemImage: "list.bullet") }

            NavigationStack {
                RecordingView()
            }
            .tabItem { Label("Capteur", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                TrendsView()
            }
            .tabItem { Label("Tendances", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack {
                HRVTestView()
            }
            .tabItem { Label("HRV", systemImage: "heart.text.square") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootTabView()
        .environment(AppEnvironment(inMemory: true))
}
