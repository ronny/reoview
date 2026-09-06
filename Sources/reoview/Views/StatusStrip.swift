import SwiftUI

struct StatusStrip: View {
    @Environment(AppState.self) private var state

    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(reachabilityText)
            } icon: {
                Circle()
                    .fill(reachabilityColour)
                    .frame(width: 8, height: 8)
            }

            if !state.cameras.isEmpty {
                Divider().frame(height: 14)
            }

            ForEach(state.cameras, id: \.id) { camera in
                CameraDots(name: camera.name, events: state.events.events(for: camera.id))
            }

            Spacer()

            Picker("Layout", selection: layoutSelection) {
                ForEach(LayoutMode.allCases) { mode in
                    Image(systemName: mode.symbol)
                        .accessibilityLabel(mode.title)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var layoutSelection: Binding<LayoutMode> {
        Binding(get: { state.layout }, set: { state.layout = $0 })
    }

    private var reachabilityText: String {
        switch state.connection {
        case .idle: "Not configured"
        case .connecting: "Connecting"
        case .connected: state.config.config.host
        case .unreachable: "NVR unreachable"
        }
    }

    private var reachabilityColour: Color {
        switch state.connection {
        case .connected: .green
        case .connecting: .yellow
        case .idle: .secondary
        case .unreachable: .red
        }
    }
}

private struct CameraDots: View {
    let name: String
    let events: EventStatusStore.CameraEvents

    var body: some View {
        HStack(spacing: 6) {
            Text(name).foregroundStyle(.secondary)
            ForEach(events.visible) { detection in
                dot(detection, active: events.isActive(detection))
            }
        }
    }

    private func dot(_ detection: Detection, active: Bool) -> some View {
        Image(systemName: detection.symbol)
            .foregroundStyle(active ? detection.colour : Color.secondary.opacity(0.3))
            .help(detection.label)
            .accessibilityLabel("\(name) \(detection.label) \(active ? "active" : "clear")")
    }
}

private extension Detection {
    var colour: Color {
        switch self {
        case .motion: .orange
        case .person: .blue
        case .vehicle: .purple
        case .pet: .teal
        case .visitor: .pink
        }
    }
}
