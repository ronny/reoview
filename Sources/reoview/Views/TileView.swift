import ReolinkNVR
import ReolinkVideo
import SwiftUI

struct TileView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var ui

    let controller: PlayerController

    var body: some View {
        ZStack {
            Color.black
            VideoPlayerView(player: controller.player)

            if controller.state != .playing {
                TileOverlay(state: controller.state)
            }

            if let camera = state.camera(for: controller.source) {
                TileControls(camera: camera)
            }

            VStack {
                HStack(alignment: .top) {
                    Text(controller.title)
                        .font(ui.font(12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, ui.length(8))
                        .padding(.vertical, ui.length(4))
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))

                    // Outside `TileControls`, which fades when the pointer
                    // leaves and is disabled with the rest of the controls when
                    // the NVR drops. An open talk session must always be
                    // visible, and must always be stoppable.
                    if let camera = state.camera(for: controller.source),
                       state.talk.isActive(cameraID: camera.id) {
                        TalkIndicator(activity: state.talk.activity) { state.talk.stop() }
                    }

                    Spacer()

                    Button {
                        state.toggleMuted(sourceID: controller.source.id)
                    } label: {
                        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(ui.font(13))
                            .frame(width: ui.length(22), height: ui.length(22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(ui.length(6))
                    .background(.black.opacity(0.45), in: .circle)
                    .help(controller.isMuted ? "Unmute" : "Mute")
                    .accessibilityLabel(controller.isMuted ? "Unmute \(controller.title)" : "Mute \(controller.title)")
                }
                Spacer()
            }
            .padding(8)
        }
        .clipShape(.rect(cornerRadius: 8))
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if let camera = state.camera(for: controller.source) {
            Picker(camera.name, selection: streamSelection(for: camera)) {
                Text("Default").tag(StreamSelection.standard)
                Text("All Streams").tag(StreamSelection.all)
                ForEach(state.sources(for: camera.id)) { source in
                    Text(state.label(for: source)).tag(StreamSelection.source(source.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
        Button(controller.isMuted ? "Unmute" : "Mute") {
            state.toggleMuted(sourceID: controller.source.id)
        }
    }

    private func streamSelection(for camera: Camera) -> Binding<StreamSelection> {
        Binding(
            get: { state.selection(for: camera.id) },
            set: { state.setSelection($0, cameraID: camera.id) }
        )
    }
}

private struct TileOverlay: View {
    @Environment(\.uiScale) private var ui

    let state: TileState

    var body: some View {
        VStack(spacing: ui.length(8)) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting")
            case .playing:
                EmptyView()
            case .retrying(let attempt):
                ProgressView().controlSize(.small)
                Text("Reconnecting, attempt \(attempt)")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(ui.font(17))
                Text(message)
                    .multilineTextAlignment(.center)
            }
        }
        .font(ui.font(10))
        .foregroundStyle(.white)
        .padding(ui.length(12))
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .padding(16)
    }
}
