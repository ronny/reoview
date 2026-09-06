import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: ui.length(16)) {
            Text("NVR").font(ui.font(13, weight: .semibold))

            Form {
                TextField("Host", text: $host, prompt: Text("192.168.8.215"))
                TextField("User name", text: $username)
                SecureField("Password", text: $password, prompt: Text(passwordPrompt))
            }
            .formStyle(.grouped)

            Text("The password is kept in the keychain, not in the app settings.")
                .font(ui.font(10))
                .foregroundStyle(.secondary)

            Text("Appearance").font(ui.font(13, weight: .semibold))

            Form {
                LabeledContent("Text size") {
                    HStack(spacing: ui.length(8)) {
                        Slider(value: scale, in: AppConfig.uiScaleRange, step: 0.1)
                            .accessibilityLabel("Text size")
                        Text(scalePercentage)
                            .monospacedDigit()
                            .frame(width: ui.length(44), alignment: .trailing)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty || isSaving)
            }
        }
        .font(ui.font(13))
        .padding(ui.length(20))
        .frame(width: ui.length(420))
        .task {
            host = state.config.config.host
            username = state.config.config.username
        }
    }

    private var scale: Binding<Double> {
        Binding(get: { state.uiScale }, set: { state.uiScale = $0 })
    }

    private var scalePercentage: String {
        "\(Int((state.uiScale * 100).rounded()))%"
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
