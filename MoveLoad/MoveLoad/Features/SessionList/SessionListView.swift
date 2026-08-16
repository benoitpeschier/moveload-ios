import SwiftUI
import PersistenceKit

struct SessionListView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var sessions: [Session] = []
    @State private var sessionPendingDelete: Session?
    @State private var deleteErrorMessage: String?

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
                guard let session = sessionPendingDelete else { return }
                sessionPendingDelete = nil
                Task { await delete(session) }
            }
        } message: {
            Text("Les données de cette séance seront définitivement supprimées de l'appareil et du tableau de bord de l'entraîneur.")
        }
        .alert(
            "Suppression impossible",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private func delete(_ session: Session) async {
        do {
            try await appEnvironment.deleteSession(session)
            reload()
        } catch {
            // Say plainly that nothing was deleted, rather than leaving the
            // athlete to assume the coach can no longer see the session.
            deleteErrorMessage = "La séance n'a pas pu être retirée du tableau de bord de l'entraîneur, elle a donc été conservée. Vérifie ta connexion et réessaie.\n\n(\(error.localizedDescription))"
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
            Text(session.displayTitle)
                .font(.headline)
            // Keep the date visible even when a name replaces it in the title,
            // since that's what distinguishes two sessions named alike.
            if session.name?.isEmpty == false {
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(Int(session.duration / 60)) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
