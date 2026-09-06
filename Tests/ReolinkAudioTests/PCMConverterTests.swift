import AVFoundation
import Foundation
import Testing
@testable import ReolinkAudio

@Suite("PCM conversion")
struct PCMConverterTests {
    @Test("Hardware rates resample to the rate the camera asked for", arguments: [44_100.0, 48_000.0, 16_000.0])
    func resamplesFromHardwareRates(rate: Double) throws {
        let converter = try PCMConverter(target: TalkAudioFormat())
        let samples = try converter.convert(makeFloatBuffer(sampleRate: rate, frames: AVAudioFrameCount(rate)))

        // One second in, one second out. The resampler keeps back a few hundred
        // samples of filter latency on its first buffer.
        #expect(samples.count > 15_500)
        #expect(samples.count <= 16_000)
        #expect(samples.contains { $0 != 0 })
    }

    @Test("Float input becomes 16-bit at full scale")
    func scalesToInt16() throws {
        let converter = try PCMConverter(target: TalkAudioFormat())
        let samples = try converter.convert(makeFloatBuffer(sampleRate: 16_000, frames: 16_000))
        let peak = samples.map { abs(Int($0)) }.max() ?? 0

        // A 0.5 full-scale sine is about 16384.
        #expect(peak > 14_000)
        #expect(peak <= 32_767)
    }

    @Test("A rate change mid-stream rebuilds the converter instead of failing")
    func followsAChangeOfInputRate() throws {
        let converter = try PCMConverter(target: TalkAudioFormat())
        _ = try converter.convert(makeFloatBuffer(sampleRate: 48_000, frames: 4800))
        #expect(converter.currentSourceRate == 48_000)

        let after = try converter.convert(makeFloatBuffer(sampleRate: 44_100, frames: 4410))
        #expect(converter.currentSourceRate == 44_100)
        #expect(after.count > 1_300)
        #expect(after.count <= 1_600)
    }

    @Test("Stereo input is mixed down to mono")
    func mixesToMono() throws {
        let converter = try PCMConverter(target: TalkAudioFormat())
        let samples = try converter.convert(makeFloatBuffer(sampleRate: 48_000, frames: 48_000, channels: 2))
        #expect(samples.count > 14_500)
        #expect(samples.count <= 16_000)
    }

    @Test("A different device rate gives a different sample count")
    func honoursTheRequestedRate() throws {
        let fast = try PCMConverter(target: TalkAudioFormat(sampleRate: 16_000))
        let slow = try PCMConverter(target: TalkAudioFormat(sampleRate: 8_000))
        let fastCount = try fast.convert(makeFloatBuffer(sampleRate: 48_000, frames: 48_000)).count
        let slowCount = try slow.convert(makeFloatBuffer(sampleRate: 48_000, frames: 48_000)).count

        #expect(abs(fastCount - 2 * slowCount) < 64)
    }
}
