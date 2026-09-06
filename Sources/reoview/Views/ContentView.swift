import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.bannerMessage {
                BannerView(message: message) { showsSettings = true }
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

    var body: some View {
        HStack(spacing: ui.length(8)) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
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
