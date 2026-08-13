import SwiftUI
import PersistenceKit

struct SessionListView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var sessions: [Session] = []
    @State private var sessionPendingDelete: Session?

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "Aucune séance",
                    systemImage: "figure.run",
                    description: Text("Démarre un enregistrement depuis l'onglet Capteur.")
                )
            } else {
                ForEach(sessions, id: \.id) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sessionPendingDelete = session
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Séances")
        .navigationDestination(for: UUID.self) { sessionID in
            if let session = sessions.first(where: { $0.id == sessionID }) {
                SessionDetailView(session: session)
            }
        }
        .task { reload() }
        .refreshable { reload() }
        .alert(
            "Supprimer cette séance ?",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { if !$0 { sessionPendingDelete = nil } }
            )
        ) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                if let session = sessionPendingDelete {
                    try? appEnvironment.deleteSession(session)
                    reload()
                }
                sessionPendingDelete = nil
            }
        } message: {
            Text("Les données de cette séance seront définitivement supprimées de l'appareil.")
        }
    }

    private func reload() {
        sessions = (try? appEnvironment.allSessions()) ?? []
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            Text("\(Int(session.duration / 60)) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
