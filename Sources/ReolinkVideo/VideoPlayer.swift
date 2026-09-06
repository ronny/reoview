import AppKit

/// The seam under the video engine.
///
/// VLCKit is the only implementation in v1. Everything that does not depend on
/// the engine — reconnect backoff, mute state, the walk through candidate URLs —
/// belongs to the caller, not here.
@MainActor
public protocol VideoPlayer: AnyObject {
    /// The view that shows the video. It is created once and reused.
    var view: NSView { get }

    var state: VideoPlayerState { get }

    /// Emits every change of `state`. One consumer per player.
    var states: AsyncStream<VideoPlayerState> { get }

    func play(url: URL)
    func stop()
    func setMuted(_ muted: Bool)
    func snapshot() async -> NSImage?
}

public enum VideoPlayerState: Sendable, Equatable {
    case idle
    case opening
    case playing
    case stopped
    case failed(String)
}
