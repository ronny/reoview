import AppKit
import SwiftUI

/// Hosts a `VideoPlayer`'s view. It holds no lifecycle logic: play, stop and
/// reconnect belong to the caller.
public struct VideoPlayerView: NSViewRepresentable {
    private let player: any VideoPlayer

    public init(player: any VideoPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> NSView {
        player.view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
