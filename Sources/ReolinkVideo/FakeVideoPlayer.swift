import AppKit

/// A `VideoPlayer` for previews and tests. It shows a solid colour and emits
/// only the states the caller asks it to emit.
@MainActor
public final class FakeVideoPlayer: VideoPlayer {
    public let view: NSView

    public private(set) var state: VideoPlayerState = .idle

    public let states: AsyncStream<VideoPlayerState>

    /// Every URL passed to `play(url:)`, in order.
    public private(set) var playedURLs: [URL] = []

    public private(set) var stopCount = 0

    public private(set) var isMuted = false

    /// Returned by `snapshot()`.
    public var snapshotImage: NSImage?

    private let continuation: AsyncStream<VideoPlayerState>.Continuation

    public init(color: NSColor = .darkGray) {
        view = SolidColorView(color: color)
        let (stream, continuation) = AsyncStream<VideoPlayerState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        states = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    public func play(url: URL) {
        playedURLs.append(url)
        emit(.opening)
    }

    public func stop() {
        stopCount += 1
        emit(.stopped)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    public func snapshot() async -> NSImage? {
        snapshotImage
    }

    /// Drives the state stream by hand.
    public func emit(_ next: VideoPlayerState) {
        guard next != state else { return }
        state = next
        continuation.yield(next)
    }

    /// Ends `states`. A consumer's `for await` loop returns.
    public func finish() {
        continuation.finish()
    }
}

private final class SolidColorView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}
