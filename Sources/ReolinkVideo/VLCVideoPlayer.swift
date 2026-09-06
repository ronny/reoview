import AppKit
import Foundation
import VLCKit

@MainActor
public final class VLCVideoPlayer: VideoPlayer {
    /// Per-media options. libvlc wants the `:` prefix here, not `--`.
    ///
    /// `:rtsp-tcp` matters because the NVR drops UDP interleaved frames under
    /// load. `:network-caching` trades latency against jitter tolerance.
    nonisolated static func mediaOptions(networkCachingMilliseconds: Int) -> [String] {
        [":rtsp-tcp", ":network-caching=\(networkCachingMilliseconds)"]
    }

    public var view: NSView { videoView }

    public private(set) var state: VideoPlayerState = .idle

    public let states: AsyncStream<VideoPlayerState>

    private let videoView: VLCVideoView
    private let player: VLCMediaPlayer
    private let continuation: AsyncStream<VideoPlayerState>.Continuation
    private let networkCachingMilliseconds: Int
    private var delegateShim: DelegateShim?
    private var muted = false

    public init(networkCachingMilliseconds: Int = 300) {
        let videoView = VLCVideoView(frame: .zero)
        videoView.backColor = .black
        videoView.fillScreen = false
        self.videoView = videoView
        self.networkCachingMilliseconds = networkCachingMilliseconds

        player = VLCMediaPlayer(library: VLCLibraryHost.shared)
        player.drawable = videoView

        let (stream, continuation) = AsyncStream<VideoPlayerState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        states = stream
        self.continuation = continuation

        let shim = DelegateShim(
            onState: { [weak self] vlcState in
                Task { @MainActor in self?.handle(vlcState) }
            },
            onTimeChanged: { [weak self] in
                Task { @MainActor in self?.handleFrameAdvanced() }
            }
        )
        delegateShim = shim
        player.delegate = shim
    }

    deinit {
        continuation.finish()
    }

    public func play(url: URL) {
        let media = VLCMedia(url: url)
        for option in Self.mediaOptions(networkCachingMilliseconds: networkCachingMilliseconds) {
            media.addOption(option)
        }
        player.media = media
        applyMute()
        player.play()
        transition(to: .opening)
    }

    public func stop() {
        player.stop()
        player.media = nil
        transition(to: .stopped)
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        applyMute()
    }

    public func snapshot() async -> NSImage? {
        guard player.hasVideoOut else { return nil }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reolink-snapshot-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: path.path, withWidth: 0, andHeight: 0)

        // libvlc only reports completion through a delegate notification that
        // fires on its own thread. Watching the file avoids a second hop and a
        // continuation that may never be resumed when the snapshot fails.
        defer { try? FileManager.default.removeItem(at: path) }
        for _ in 0..<40 {
            if let image = NSImage(contentsOf: path), image.isValid {
                return image
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func applyMute() {
        player.audio?.isMuted = muted
    }

    /// VLCKit does not reliably report `.playing` for an RTSP stream: it can sit
    /// in `buffering` while frames are already on screen. An advancing clock is
    /// the only dependable sign that video is running.
    private func handleFrameAdvanced() {
        guard state == .opening else { return }
        transition(to: .playing)
    }

    private func handle(_ vlcState: VLCMediaPlayerState) {
        guard let next = VideoPlayerState(vlcState) else { return }
        transition(to: next)
    }

    private func transition(to next: VideoPlayerState) {
        guard next != state else { return }
        state = next
        continuation.yield(next)
    }
}

extension VideoPlayerState {
    /// Maps a libvlc player state onto the engine-independent state.
    ///
    /// Returns `nil` for states that carry no transition for a live stream:
    /// `paused` never happens on RTSP, and `esAdded` fires repeatedly while a
    /// stream opens.
    init?(_ vlcState: VLCMediaPlayerState) {
        switch vlcState {
        case .opening, .buffering:
            self = .opening
        case .playing:
            self = .playing
        case .stopped, .ended:
            self = .stopped
        case .error:
            self = .failed("VLC reported a playback error")
        case .paused, .esAdded:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// VLCKit calls its delegate on a libvlc thread and holds the delegate weakly.
/// This shim is the only thing that crosses threads; it forwards a plain enum
/// value to the main actor.
private final class DelegateShim: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    private let onState: @Sendable (VLCMediaPlayerState) -> Void
    private let onTimeChanged: @Sendable () -> Void

    init(
        onState: @escaping @Sendable (VLCMediaPlayerState) -> Void,
        onTimeChanged: @escaping @Sendable () -> Void
    ) {
        self.onState = onState
        self.onTimeChanged = onTimeChanged
        super.init()
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        onState(player.state)
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        onTimeChanged()
    }
}
