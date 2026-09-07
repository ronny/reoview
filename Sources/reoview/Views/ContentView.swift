import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui
    @State private var showsSettings = false
    @State private var showsOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.bannerMessage {
                BannerView(
                    message: message,
                    onSettings: { showsSettings = true },
                    onRetry: { Task { await state.retryConnection() } }
                )
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusStrip { showsSettings = true }
        }
        .onExitCommand { state.unfocus() }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
                .environment(state)
                .environment(\.uiScale, ui)
        }
        // A fresh install lands here with nothing configured, so the wizard
        // takes the window before the grid can show an empty one. It is not
        // dismissable: there is no app without an NVR to point it at.
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView()
                .environment(state)
                .environment(\.uiScale, ui)
        }
        .task { showsOnboarding = state.needsOnboarding }
    }

    @ViewBuilder
    private var content: some View {
        if let focused = state.focusedSourceID, let controller = state.controllers[focused] {
            TileView(controller: controller)
                .padding(8)
                .onTapGesture(count: 2) { state.unfocus() }
        } else {
            GridView()
        }
    }
}

private struct BannerView: View {
    @Environment(\.uiScale) private var ui

    let message: String
    var onSettings: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: ui.length(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.link)
            Button("Settings", action: onSettings)
                .buttonStyle(.link)
        }
        .font(ui.font(12))
        .padding(.horizontal, ui.length(12))
        .padding(.vertical, ui.length(8))
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.85))
        .foregroundStyle(.white)
    }
}
