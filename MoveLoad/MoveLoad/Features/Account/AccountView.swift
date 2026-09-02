import SwiftUI
import SyncKit

/// Sign-in and account creation.
///
/// The app has synced under an anonymous account until now: one identity per
/// install, lost on reinstall, and impossible to name. A real account is the
/// first piece of the team model — a person a coach can invite — so it lands
/// on its own, before any data moves.
struct AccountView: View {
    enum Mode: Hashable {
        case signIn
        case create
    }

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let account: AuthAccount?
    /// Lets Settings refresh its own row without re-reading the Keychain.
    let onChange: (AuthAccount?) -> Void

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        // Firebase's own minimum. Checking it here turns a round trip and a
        // server error into an inert button.
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 6
            && !isWorking
    }

    var body: some View {
        Form {
            if let account, !account.isAnonymous {
                signedInSection(account)
            } else {
                credentialsSection
            }
        }
        .navigationTitle("Compte")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func signedInSection(_ account: AuthAccount) -> some View {
        Section {
            LabeledContent("Connecté en tant que", value: account.email ?? "")
        } footer: {
            Text("Vos séances sont enregistrées sous ce compte. En vous connectant avec la même adresse sur un autre téléphone, vous les retrouverez.")
        }

        Section {
            Button(role: .destructive) {
                Task {
                    await appEnvironment.syncService.signOut()
                    onChange(nil)
                    dismiss()
                }
            } label: {
                Text("Se déconnecter")
            }
        } footer: {
            Text("Se déconnecter n'efface rien : ni les séances de ce téléphone, ni celles déjà envoyées au coach.")
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section {
            // An empty label string would become an empty catalogue key; the
            // segmented style shows no label anyway.
            Picker(selection: $mode) {
                Text("Se connecter").tag(Mode.signIn)
                Text("Créer un compte").tag(Mode.create)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            // A message about the other mode's attempt would be misleading here.
            .onChange(of: mode) { _, _ in errorMessage = nil }
        }

        Section {
            TextField("Adresse e-mail", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Mot de passe", text: $password)
                .textContentType(mode == .create ? .newPassword : .password)

            Button {
                Task { await submit() }
            } label: {
                if isWorking {
                    ProgressView()
                } else {
                    Text(mode == .create ? "Créer le compte" : "Se connecter")
                }
            }
            .disabled(!canSubmit)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text(mode == .create
                 ? "Le mot de passe doit faire au moins 6 caractères. Notez-le : il n'y a pas encore de réinitialisation par e-mail."
                 : "Utilisez l'adresse et le mot de passe créés sur votre premier téléphone.")
        }
    }

    private func submit() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let account: AuthAccount
            switch mode {
            case .create:
                account = try await appEnvironment.syncService.createAccount(
                    email: email, password: password)
            case .signIn:
                account = try await appEnvironment.syncService.signIn(
                    email: email, password: password)
            }
            // The password never outlives the screen that collected it.
            password = ""
            onChange(account)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
