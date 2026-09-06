import AVFoundation
import Foundation
import Testing
@testable import ReolinkAudio

@Suite("Speech source", .serialized)
struct SpeechSourceTests {
    @Test("A short phrase comes back in the requested format")
    func shortPhrase() async throws {
        let format = TalkAudioFormat()
        let source = SpeechSource(text: "Hello. Nobody is home.", format: format)
        #expect(source.format == format)

        let samples = try await collect(source, timeout: .seconds(30))

        // The synthesiser writes 22050 Hz float; what comes out here must be
        // 16000 Hz Int16, so a phrase of a second or two lands in this range.
        #expect(samples.count > 16_000 / 4)
        #expect(samples.count < 16_000 * 15)
        #expect(samples.contains { $0 != 0 })
    }

    @Test("The sample count follows the requested rate")
    func honoursTheRequestedRate() async throws {
        let text = "The parcel is at the front door."
        let fast = try await collect(SpeechSource(text: text, format: TalkAudioFormat(sampleRate: 16_000)))
        let slow = try await collect(SpeechSource(text: text, format: TalkAudioFormat(sampleRate: 8_000)))

        #expect(slow.count > 0)
        let ratio = Double(fast.count) / Double(slow.count)
        #expect(abs(ratio - 2) < 0.02)
    }

    @Test("Speech feeds whole ADPCM blocks")
    func feedsTheEncoder() async throws {
        let format = TalkAudioFormat()
        let samples = try await collect(SpeechSource(text: "Hello there.", format: format))
        var encoder = try IMAADPCMEncoder(format: format)
        var blocks = encoder.encode(samples)
        if let tail = encoder.finish() { blocks.append(tail) }

        #expect(blocks.count == (samples.count + 1023) / 1024)
        #expect(blocks.allSatisfy { $0.count == 516 })
    }

    @Test("Nothing to say is an error, not an empty stream")
    func emptyText() async throws {
        await #expect(throws: AudioSourceError.self) {
            _ = try await collect(SpeechSource(text: "   \n "))
        }
    }

    @Test("stop() before the stream starts is harmless")
    func stopBeforeStart() {
        let source = SpeechSource(text: "unused")
        source.stop()
        source.stop()
    }
}
