import ReolinkVideo
import SwiftUI

struct TileView: View {
    @Environment(AppState.self) private var state

    let controller: PlayerController

    var body: some View {
        ZStack {
            Color.black
            VideoPlayerView(player: controller.player)

            if controller.state != .playing {
                TileOverlay(state: controller.state)
            }

            VStack {
                HStack(alignment: .top) {
                    Text(controller.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))

                    Spacer()

                    Button {
                        state.toggleMuted(sourceID: controller.source.id)
                    } label: {
                        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45), in: .circle)
                    .help(controller.isMuted ? "Unmute" : "Mute")
                    .accessibilityLabel(controller.isMuted ? "Unmute \(controller.title)" : "Mute \(controller.title)")
                }
                Spacer()
            }
            .padding(8)
        }
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct TileOverlay: View {
    let state: TileState

    var body: some View {
        VStack(spacing: 8) {
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
                    .font(.title2)
                Text(message)
                    .multilineTextAlignment(.center)
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .padding(16)
    }
}
