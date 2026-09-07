import AVFoundation
import AppKit
import ReolinkAudio
import SwiftUI
import UserNotifications

/// The first-run wizard: credentials, then the three things macOS makes the app
/// ask for.
///
/// Every prompt is behind its own button. macOS raises a permission prompt as a
/// side effect of the first call that needs it, which on a fresh install means
/// system dialogs appearing over an empty window with nothing on screen to say
/// what asked for them. Here the reason is given first, and the user decides
/// when each one appears.
///
/// The local network step is why the credentials come first: that prompt is
/// raised by reaching the NVR, so there is nothing to ask about until there is
/// a host to reach.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case credentials
        case permissions
    }

    @State private var step: Step = .credentials
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSaving = false
    @State private var credentialsError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .credentials:
                        CredentialsStep(
                            host: $host,
                            username: $username,
                            password: $password,
                            error: credentialsError
                        )
                    case .permissions:
                        PermissionsStep()
                    }
                }
                .padding(ui.length(20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .font(ui.font(13))
        .frame(width: ui.length(540), height: ui.length(580))
        .task {
            host = state.config.config.host
            username = state.config.config.username
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: ui.length(12)) {
            Image(systemName: "video.fill")
                .font(ui.font(22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: ui.length(2)) {
                Text("Set up ReoView")
                    .font(ui.font(17).weight(.semibold))
                Text(subtitle)
                    .font(ui.font(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(step == .credentials ? "Step 1 of 2" : "Step 2 of 2")
                .font(ui.font(11))
                .foregroundStyle(.secondary)
        }
        .padding(ui.length(20))
    }

    private var subtitle: String {
        switch step {
        case .credentials: "Where the NVR is, and who to sign in as."
        case .permissions: "What macOS has to let ReoView do."
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if step == .permissions {
                Button("Back") { step = .credentials }
            }
            Spacer()
            switch step {
            case .credentials:
                Button("Continue") { saveCredentials() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            case .permissions:
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ui.length(16))
    }

    private var canContinue: Bool {
        !isSaving
            && !host.trimmed.isEmpty
            && !username.trimmed.isEmpty
            && !password.isEmpty
    }

    // MARK: - Actions

    /// Writes the credentials down and stops there. Reaching the NVR is what
    /// raises the local network prompt, and that belongs to its own button on
    /// the next step.
    private func saveCredentials() {
        isSaving = true
        credentialsError = nil
        let host = host.trimmed
        let username = username.trimmed
        let password = password
        Task {
            let saved = await state.storeCredentials(host: host, username: username, password: password)
            isSaving = false
            if saved {
                step = .permissions
            } else {
                credentialsError = "The password could not be saved to the keychain."
            }
        }
    }

    private func finish() {
        state.completeOnboarding()
        let shouldConnect = state.connection != .connected
        dismiss()
        if shouldConnect {
            Task { await state.retryConnection() }
        }
    }
}

// MARK: - Step 1

private struct CredentialsStep: View {
    @Environment(\.uiScale) private var ui

    @Binding var host: String
    @Binding var username: String
    @Binding var password: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ui.length(14)) {
            Text("ReoView talks to a Reolink NVR, not to a camera on its own.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: ui.length(10), verticalSpacing: ui.length(8)) {
                GridRow {
                    Text("Host")
                        .gridColumnAlignment(.trailing)
                    TextField("Host", text: $host, prompt: Text("192.168.1.100"))
                        .labelsHidden()
                }
                GridRow {
                    Text("User name")
                    TextField("User name", text: $username)
                        .labelsHidden()
                }
                GridRow {
                    Text("Password")
                    SecureField("Password", text: $password)
                        .labelsHidden()
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(ui.font(11))
                    .foregroundStyle(.red)
            }

            Text(
                "The password is kept in the keychain of this Mac, never in the app settings. "
                    + "Use an NVR account with administrator rights: the camera controls need them."
            )
            .font(ui.font(11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2

private struct PermissionsStep: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui

    @State private var microphone: PermissionStatus = .unknown
    @State private var notifications: PermissionStatus = .unknown
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: ui.length(14)) {
            Text("Each button below puts one macOS prompt on screen. Nothing is asked for until you press it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                symbol: "network",
                title: "Reach the NVR",
                detail: localNetworkDetail,
                status: localNetwork,
                actionTitle: localNetworkActionTitle,
                settingsPane: Self.localNetworkPane,
                isBusy: state.connection == .connecting
            ) {
                await state.retryConnection()
            }

            PermissionRow(
                symbol: "bell.badge",
                title: "Notifications",
                detail: "Posts a banner when someone rings the doorbell. The dots in the status strip work either way.",
                status: notifications,
                actionTitle: "Allow",
                settingsPane: Self.notificationsPane,
                isBusy: isAsking
            ) {
                isAsking = true
                await state.notifier.requestAuthorization()
                notifications = await notificationStatus()
                isAsking = false
            }

            PermissionRow(
                symbol: "mic",
                title: "Microphone",
                detail: microphoneDetail,
                status: microphone,
                actionTitle: "Allow",
                settingsPane: Self.microphonePane,
                isBusy: isAsking
            ) {
                isAsking = true
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                microphone = Self.microphoneStatus()
                isAsking = false
            }

            Text(
                "Notifications and the microphone are optional. Everything else works without them, "
                    + "and both can be turned on later in System Settings."
            )
            .font(ui.font(11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            microphone = Self.microphoneStatus()
            notifications = await notificationStatus()
        }
    }

    // MARK: Local network

    /// macOS offers no way to read the local network grant, so the only honest
    /// answer is whether the NVR actually answered.
    private var localNetwork: PermissionStatus {
        switch state.connection {
        case .connected: .granted
        case .connecting, .idle: .unknown
        case .unreachable(let message): message == AppState.localNetworkMessage ? .waiting : .failed(message)
        }
    }

    private var localNetworkDetail: String {
        if case .connected = state.connection {
            return "Signed in to \(state.config.config.host)."
        }
        return "macOS 15 and later ask before an app may reach devices on this network. "
            + "Connect makes the first request, which is what puts that prompt on screen."
    }

    private var localNetworkActionTitle: String {
        if case .unreachable = state.connection { return "Try Again" }
        return "Connect"
    }

    // MARK: Status

    private static func microphoneStatus() -> PermissionStatus {
        guard MicrophoneSource.hasInputDevice() else { return .failed("This Mac has no audio input device.") }
        return switch MicrophoneSource.authorization {
        case .authorized: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    private var microphoneDetail: String {
        MicrophoneSource.hasInputDevice()
            ? "Needed to hold the talk button and speak to whoever is at the door. The stored phrases do not use it."
            : "No audio input device is attached, so hold to talk cannot be used."
    }

    private func notificationStatus() async -> PermissionStatus {
        guard state.notifier.isAvailable else { return .unknown }
        return switch await state.notifier.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    // MARK: System Settings panes

    private static let localNetworkPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    private static let microphonePane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    private static let notificationsPane =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
}

/// What macOS has decided about one permission.
///
/// `waiting` is the local network case, where the prompt has been raised but
/// the answer arrives too late for the request that raised it.
private enum PermissionStatus: Equatable {
    case unknown
    case waiting
    case granted
    case denied
    case failed(String)

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied, .failed: "xmark.circle.fill"
        case .waiting: "clock.fill"
        case .unknown: "circle.dashed"
        }
    }

    var colour: Color {
        switch self {
        case .granted: .green
        case .denied, .failed: .red
        case .waiting: .orange
        case .unknown: .secondary
        }
    }

    var message: String? {
        switch self {
        case .failed(let message): message
        case .waiting: "Waiting for the answer. Press Try Again once you have allowed it."
        case .denied: "Refused. Turn it on in System Settings, then come back."
        case .granted, .unknown: nil
        }
    }

    /// A refusal cannot be asked for twice: the second call returns the stored
    /// answer without showing anything, so the only way on is System Settings.
    var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }
}

private struct PermissionRow: View {
    @Environment(\.uiScale) private var ui

    let symbol: String
    let title: String
    let detail: String
    let status: PermissionStatus
    let actionTitle: String
    let settingsPane: String
    let isBusy: Bool
    let action: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ui.length(12)) {
            Image(systemName: symbol)
                .font(ui.font(16))
                .frame(width: ui.length(24))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: ui.length(4)) {
                HStack(spacing: ui.length(6)) {
                    Text(title).font(ui.font(13).weight(.medium))
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.colour)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .font(ui.font(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = status.message {
                    Text(message)
                        .font(ui.font(11))
                        .foregroundStyle(status.colour)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: ui.length(8))

            Group {
                if status.isDenied {
                    Button("Open Settings") { openSettings() }
                } else if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(status == .granted ? "Recheck" : actionTitle) {
                        Task { await action() }
                    }
                }
            }
            .frame(width: ui.length(108), alignment: .trailing)
        }
        .padding(ui.length(12))
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }

    private func openSettings() {
        guard let url = URL(string: settingsPane) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
