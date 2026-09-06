import Testing
import VLCKit

@testable import ReolinkVideo

@Suite("VLC state mapping")
struct VideoPlayerStateMappingTests {
    @Test(
        "opening states map to .opening",
        arguments: [VLCMediaPlayerState.opening]
    )
    func opening(vlcState: VLCMediaPlayerState) {
        #expect(VideoPlayerState(vlcState) == .opening)
    }

    @Test(
        "end states map to .stopped",
        arguments: [VLCMediaPlayerState.stopped]
    )
    func stopped(vlcState: VLCMediaPlayerState) {
        #expect(VideoPlayerState(vlcState) == .stopped)
    }

    @Test("playing maps to .playing")
    func playing() {
        #expect(VideoPlayerState(.playing) == .playing)
    }

    @Test("error maps to .failed with a message")
    func failed() throws {
        let mapped = try #require(VideoPlayerState(.error))
        guard case .failed(let message) = mapped else {
            Issue.record("expected .failed, got \(mapped)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test(
        "states with no equivalent map to nil",
        arguments: [VLCMediaPlayerState.paused, .stopping, .nothingSpecial]
    )
    func ignored(vlcState: VLCMediaPlayerState) {
        #expect(VideoPlayerState(vlcState) == nil)
    }

    @Test("the failed message carries no stream URL")
    func failedMessageHasNoCredentials() throws {
        let mapped = try #require(VideoPlayerState(.error))
        guard case .failed(let message) = mapped else { return }
        #expect(!message.contains("rtsp"))
        #expect(!message.contains("@"))
    }
}

@Suite("Media options")
struct MediaOptionTests {
    @Test("RTSP is forced over TCP")
    func forcesTCP() {
        let options = VLCVideoPlayer.mediaOptions(networkCachingMilliseconds: 300)
        #expect(options.contains(":rtsp-tcp"))
    }

    @Test("network caching is passed through")
    func networkCaching() {
        let options = VLCVideoPlayer.mediaOptions(networkCachingMilliseconds: 300)
        #expect(options.contains(":network-caching=300"))
    }

    @Test("per-media options use the colon form, not the dash form")
    func colonForm() {
        for option in VLCVideoPlayer.mediaOptions(networkCachingMilliseconds: 300) {
            #expect(option.hasPrefix(":"))
        }
    }
}

@Suite("Library options")
struct LibraryOptionTests {
    @Test("screensaver inhibition is turned off")
    func screensaverOff() {
        #expect(VLCLibraryHost.options.contains("--disable-screensaver=0"))
    }

    @Test("library options use the dash form")
    func dashForm() {
        for option in VLCLibraryHost.options {
            #expect(option.hasPrefix("--"))
        }
    }
}
