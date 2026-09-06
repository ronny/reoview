import Foundation
import Testing
@testable import ReolinkAudio

@Suite("IMA ADPCM encoder")
struct IMAADPCMEncoderTests {
    private let talk = TalkAudioFormat()

    // MARK: Nibble order, against ffmpeg

    @Test("ffmpeg packs the earlier sample in the low nibble")
    func ffmpegIsLowNibbleFirst() {
        // Read the same reference block both ways and see which one is audio.
        // Nothing here depends on how the codes were chosen, only on which half
        // of each byte comes first. Measured: 29.1 dB against 6.9 dB on the
        // tone, 9.3 dB against 2.9 dB on the square wave.
        for (reference, source) in Self.references {
            var low = ADPCMDecoder(nibbleOrder: .lowNibbleFirst)
            var high = ADPCMDecoder(nibbleOrder: .highNibbleFirst)
            let lowFirst = signalToNoise(source, low.decode(block: Data(reference)))
            let highFirst = signalToNoise(source, high.decode(block: Data(reference)))

            #expect(lowFirst > 8)
            #expect(lowFirst > highFirst + 5)
        }
    }

    @Test("The reference blocks are reproduced bit for bit by ffmpeg's own arithmetic")
    func ffmpegModelIsExact() {
        // Reproducing ffmpeg exactly pins the whole layout: a 4-byte DVI state
        // header of predictor, step index and a reserved zero, then one nibble
        // per sample with the earlier sample low.
        for (reference, source) in Self.references {
            var model = FFmpegIMAEncoder()
            let block = [0, 0, 0, 0] + FFmpegIMAEncoder.pack(model.codes(for: source))

            #expect(block.count == 1024)
            let differing = zip(block, reference).filter { $0 != $1 }.count
            #expect(differing == 0)
        }
    }

    @Test("This encoder agrees with ffmpeg on the packing and on most of the codes")
    func matchesFFmpegExceptWhereFFmpegDrifts() throws {
        for (reference, source) in Self.references {
            try compareWithFFmpeg(reference: reference, source: source)
        }
    }

    private func compareWithFFmpeg(reference: [UInt8], source: [Int16]) throws {
        var encoder = try IMAADPCMEncoder(format: TalkAudioFormat(samplesPerBlock: 2040))
        let blocks = encoder.encode(source)
        let block = Array(try #require(blocks.first))

        #expect(block.count == 1024)
        #expect(Array(block[0 ..< 4]) == [0, 0, 0, 0])

        // Not byte for byte, and not because of the nibble order. ffmpeg's
        // quantiser and its reconstruction are both a little different from an
        // IMA decoder's, so the two encoders sometimes pick a neighbouring code.
        // See FFmpegIMAEncoder for why this encoder does not copy that.
        let agreeing = zip(block[4...], reference[4...]).filter { $0 == $1 }.count
        #expect(Double(agreeing) / 1020 > 0.6)

        // Packed the other way round, agreement collapses. That is the check
        // that matters: the disputed field is the packing, not the quantiser.
        let swapped = block[4...].map { ($0 >> 4) | ($0 << 4) }
        let agreeingSwapped = zip(swapped, reference[4...]).filter { $0 == $1 }.count
        #expect(Double(agreeingSwapped) / 1020 < 0.2)
        #expect(agreeing > agreeingSwapped * 3)

        // Both streams decode to the same signal, which is the point.
        var decoder = ADPCMDecoder()
        #expect(signalToNoise(source, decoder.decode(block: Data(block))) > 8)
    }

    private static let references: [(reference: [UInt8], source: [Int16])] = [
        (TestVectors.ffmpegToneReference, TestVectors.tone(count: 2040)),
        (TestVectors.ffmpegSquareReference, TestVectors.square(count: 2040)),
    ]

    // MARK: Block geometry

    @Test("1024 samples make one 516-byte block")
    func blockGeometry() throws {
        var encoder = try IMAADPCMEncoder(format: talk)
        #expect(encoder.blockSize == 516)

        let none = encoder.encode(TestVectors.tone(count: 1023))
        #expect(none.isEmpty)
        #expect(encoder.bufferedSampleCount == 1023)

        let blocks = encoder.encode(TestVectors.tone(count: 1024 * 3 - 1023))
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.count == 516 })
        #expect(encoder.bufferedSampleCount == 0)

        let nothingLeft = encoder.finish()
        #expect(nothingLeft == nil)
    }

    @Test("The block size follows the format, not the measured 1024")
    func honoursDeviceBlockSize() throws {
        var encoder = try IMAADPCMEncoder(format: TalkAudioFormat(sampleRate: 8000, samplesPerBlock: 256))
        #expect(encoder.blockSize == 132)

        let blocks = encoder.encode(TestVectors.tone(count: 1024))
        #expect(blocks.count == 4)
        #expect(blocks.allSatisfy { $0.count == 132 })
    }

    @Test("Predictor state runs across blocks")
    func stateCarriesAcrossBlocks() throws {
        let source = TestVectors.tone(count: 2040)

        // Cutting the same samples into two blocks must not change one nibble.
        // Only the extra header in the middle is new.
        var split = try IMAADPCMEncoder(format: TalkAudioFormat(samplesPerBlock: 1020))
        var whole = try IMAADPCMEncoder(format: TalkAudioFormat(samplesPerBlock: 2040))
        let blocks = split.encode(source)
        let single = whole.encode(source)
        #expect(blocks.count == 2)
        let singleBlock = try #require(single.first)
        #expect(blocks.flatMap { Array($0[4...]) } == Array(singleBlock[4...]))

        // The second header is the state the first block left behind.
        var decoder = ADPCMDecoder(samplesPerBlock: 1020)
        _ = decoder.decode(block: blocks[0])
        let second = Array(blocks[1])
        let carried = Int16(bitPattern: UInt16(second[0]) | (UInt16(second[1]) << 8))
        #expect(Int32(carried) == decoder.predictor)
        #expect(Int32(second[2]) == decoder.stepIndex)
        #expect(second[3] == 0)
    }

    @Test("A partial final block is padded to full length with silence")
    func partialFinalBlockIsPadded() throws {
        var encoder = try IMAADPCMEncoder(format: talk)
        let samples = TestVectors.tone(count: 1024 + 100)
        let blocks = encoder.encode(samples)
        #expect(blocks.count == 1)

        let padded = encoder.finish()
        let tail = try #require(padded)
        #expect(tail.count == 516)
        let nothingLeft = encoder.finish()
        #expect(nothingLeft == nil)

        var decoder = ADPCMDecoder()
        _ = decoder.decode(block: blocks[0])
        let decoded = decoder.decode(block: tail)
        #expect(decoded.count == 1024)

        // The 100 real samples survive, and the padding runs down to silence
        // rather than holding the last value.
        #expect(signalToNoise(Array(samples[1024...]), Array(decoded[0 ..< 100])) > 15)
        #expect(abs(Int(decoded[1023])) < 32)
    }

    // MARK: Round trip

    @Test("A round trip through the decoder stays close to the input")
    func roundTrip() throws {
        var encoder = try IMAADPCMEncoder(format: talk)
        let samples = TestVectors.tone(count: 1024 * 4)
        let blocks = encoder.encode(samples)

        var decoder = ADPCMDecoder()
        let decoded = decoder.decode(blocks: blocks)
        #expect(decoded.count == samples.count)

        // 4 bits a sample buys about 20 dB on a signal like this.
        #expect(signalToNoise(samples, decoded) > 20)

        let worst = zip(samples, decoded).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst < 3000)
    }

    @Test("Even a hard signal round trips without the decoder losing the plot")
    func roundTripOfASquareWave() throws {
        var encoder = try IMAADPCMEncoder(format: talk)
        let samples = TestVectors.square(count: 1024 * 2)
        let blocks = encoder.encode(samples)

        var decoder = ADPCMDecoder()
        let decoded = decoder.decode(blocks: blocks)

        // A square wave that jumps 60000 in one sample is the worst case for a
        // differential coder, and 8 dB is what it costs.
        #expect(signalToNoise(samples, decoded) > 8)
    }

    // MARK: Sessions and input shape

    @Test("reset() returns the encoder to a fresh one")
    func resetClearsState() throws {
        var encoder = try IMAADPCMEncoder(format: talk)
        let samples = TestVectors.tone(count: 1024)
        let first = encoder.encode(samples)
        _ = encoder.encode(TestVectors.tone(count: 500))
        encoder.reset()
        #expect(encoder.bufferedSampleCount == 0)

        let again = encoder.encode(samples)
        #expect(again == first)

        var fresh = try IMAADPCMEncoder(format: talk)
        let fromFresh = fresh.encode(samples)
        #expect(fromFresh == first)
    }

    @Test("A stream split across calls encodes the same as one call")
    func splitInputIsStable() throws {
        let samples = TestVectors.tone(count: 1024 * 2)
        var whole = try IMAADPCMEncoder(format: talk)
        var piecemeal = try IMAADPCMEncoder(format: talk)

        var pieces: [Data] = []
        for chunk in stride(from: 0, to: samples.count, by: 333) {
            let end = min(chunk + 333, samples.count)
            pieces.append(contentsOf: piecemeal.encode(Array(samples[chunk ..< end])))
        }

        let inOneGo = whole.encode(samples)
        #expect(pieces == inOneGo)
    }

    @Test("The nibble order option only swaps the halves of each byte")
    func nibbleOrderSwapsHalves() throws {
        let samples = TestVectors.tone(count: 1024)
        var low = try IMAADPCMEncoder(format: talk, nibbleOrder: .lowNibbleFirst)
        var high = try IMAADPCMEncoder(format: talk, nibbleOrder: .highNibbleFirst)
        let lowBlocks = low.encode(samples)
        let highBlocks = high.encode(samples)
        let lowBlock = Array(try #require(lowBlocks.first))
        let highBlock = Array(try #require(highBlocks.first))

        #expect(Array(lowBlock[0 ..< 4]) == Array(highBlock[0 ..< 4]))
        #expect(lowBlock[4...].map { ($0 >> 4) | ($0 << 4) } == Array(highBlock[4...]))
    }

    @Test("Formats the encoder cannot code are refused")
    func formatValidation() {
        #expect(throws: IMAADPCMEncoder.Failure.self) {
            try IMAADPCMEncoder(format: TalkAudioFormat(channels: 2))
        }
        #expect(throws: IMAADPCMEncoder.Failure.self) {
            try IMAADPCMEncoder(format: TalkAudioFormat(samplePrecision: 8))
        }
        #expect(throws: IMAADPCMEncoder.Failure.self) {
            try IMAADPCMEncoder(format: TalkAudioFormat(samplesPerBlock: 1023))
        }
        #expect(throws: Never.self) {
            try IMAADPCMEncoder(format: TalkAudioFormat(sampleRate: 8000, samplesPerBlock: 512))
        }
    }
}

/// How far the decoded signal sits above the error, in dB. Reads the way a
/// listener hears it: below about 5 dB there is nothing recognisable left.
func signalToNoise(_ reference: [Int16], _ decoded: [Int16]) -> Double {
    var signal = 0.0
    var noise = 0.0
    for (a, b) in zip(reference, decoded) {
        signal += Double(a) * Double(a)
        noise += (Double(a) - Double(b)) * (Double(a) - Double(b))
    }
    guard noise > 0 else { return .infinity }
    return 10 * log10(signal / noise)
}
