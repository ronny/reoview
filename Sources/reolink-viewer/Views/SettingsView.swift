import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NVR").font(.headline)

            Form {
                TextField("Host", text: $host, prompt: Text("192.168.8.215"))
                TextField("User name", text: $username)
                SecureField("Password", text: $password, prompt: Text(passwordPrompt))
            }
            .formStyle(.grouped)

            Text("The password is kept in the keychain, not in the app settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            host = state.config.config.host
            username = state.config.config.username
        }
    }

    private var passwordPrompt: String {
        state.config.config.username.isEmpty ? "Password" : "Leave empty to keep the saved password"
    }

    private func save() {
        isSaving = true
        let host = host
        let username = username
        let password = password
        Task {
            await state.saveSettings(host: host, username: username, password: password)
            isSaving = false
            dismiss()
        }
    }
}
