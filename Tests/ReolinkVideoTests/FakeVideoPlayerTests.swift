import AppKit
import Testing

@testable import ReolinkVideo

@Suite("FakeVideoPlayer")
@MainActor
struct FakeVideoPlayerTests {
    private let url = URL(string: "rtsp://nvr.invalid:554/h264Preview_01_sub")!

    @Test("starts idle")
    func startsIdle() {
        let player = FakeVideoPlayer()
        #expect(player.state == .idle)
        #expect(player.playedURLs.isEmpty)
    }

    @Test("play records the URL and moves to .opening")
    func playOpens() {
        let player = FakeVideoPlayer()
        player.play(url: url)
        #expect(player.playedURLs == [url])
        #expect(player.state == .opening)
    }

    @Test("stop counts and moves to .stopped")
    func stopStops() {
        let player = FakeVideoPlayer()
        player.play(url: url)
        player.stop()
        #expect(player.stopCount == 1)
        #expect(player.state == .stopped)
    }

    @Test("setMuted is recorded")
    func mute() {
        let player = FakeVideoPlayer()
        #expect(player.isMuted == false)
        player.setMuted(true)
        #expect(player.isMuted)
        player.setMuted(false)
        #expect(player.isMuted == false)
    }

    @Test("snapshot returns the configured image")
    func snapshot() async {
        let player = FakeVideoPlayer()
        #expect(await player.snapshot() == nil)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        player.snapshotImage = image
        #expect(await player.snapshot() === image)
    }

    @Test("the state stream emits every change in order")
    func streamOrder() async {
        let player = FakeVideoPlayer()
        let collected = Task { @MainActor in
            var seen: [VideoPlayerState] = []
            for await state in player.states {
                seen.append(state)
            }
            return seen
        }

        player.play(url: url)
        player.emit(.playing)
        player.stop()
        player.finish()

        #expect(await collected.value == [.opening, .playing, .stopped])
    }

    @Test("a repeated state emits nothing")
    func deduplicates() async {
        let player = FakeVideoPlayer()
        let collected = Task { @MainActor in
            var seen: [VideoPlayerState] = []
            for await state in player.states {
                seen.append(state)
            }
            return seen
        }

        player.emit(.playing)
        player.emit(.playing)
        player.emit(.failed("gone"))
        player.finish()

        #expect(await collected.value == [.playing, .failed("gone")])
    }

    @Test("the view is layer backed so it draws a solid colour")
    func viewIsLayerBacked() {
        let player = FakeVideoPlayer(color: .systemPink)
        #expect(player.view.wantsLayer)
        #expect(player.view.layer?.backgroundColor == NSColor.systemPink.cgColor)
    }
}
