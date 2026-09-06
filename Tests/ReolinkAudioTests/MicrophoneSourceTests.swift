import AVFoundation
import Foundation
import Testing
@testable import ReolinkAudio

/// Only the live test opens the input device. Everything else here stays away
/// from the hardware, so the suite passes on a machine with no microphone and
/// no permission, and never raises the system prompt.
@Suite("Microphone source")
struct MicrophoneSourceTests {
    @Test("The source reports the format it was given")
    func format() {
        let format = TalkAudioFormat(sampleRate: 8_000, samplesPerBlock: 512)
        #expect(MicrophoneSource(format: format).format == format)
    }

    @Test("stop() without a stream is harmless")
    func stopWithoutStart() {
        let source = MicrophoneSource()
        source.stop()
        source.stop()
    }

    @Test("Availability can be read without recording")
    func availabilityIsSafeToRead() {
        _ = MicrophoneSource.hasInputDevice()
        _ = MicrophoneSource.authorization
    }

    @Test(
        "A live microphone produces samples at the requested rate",
        .enabled(if: MicrophoneSource.hasInputDevice() && MicrophoneSource.authorization == .authorized)
    )
    func liveCapture() async throws {
        let format = TalkAudioFormat()
        let source = MicrophoneSource(format: format)
        var collected = 0
        let started = ContinuousClock.now

        for try await chunk in source.samples() {
            collected += chunk.count
            if collected >= format.sampleRate / 2 { break }
        }
        source.stop()

        // Half a second of audio must take about half a second to arrive. A
        // source that ignored the hardware rate would run fast or slow.
        let elapsed = ContinuousClock.now - started
        #expect(collected >= format.sampleRate / 2)
        #expect(elapsed > .milliseconds(300))
        #expect(elapsed < .seconds(5))
    }
}
