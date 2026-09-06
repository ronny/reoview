import Foundation

/// Which sample of a pair goes in the low half of a packed byte.
///
/// The Reolink talk implementations disagree. `reolink_talk`
/// (`ima_adpcm_encode_dvi_blocks`) and `reolens` pack the earlier sample in the
/// low nibble; `neolink.net` (`Adpcm.cs`) packs it in the high nibble.
///
/// Low nibble first is right. ffmpeg is the reference for IMA WAV, and its
/// blocks reproduce here bit for bit only when the earlier sample is packed low
/// (`Tests/ReolinkAudioTests/FFmpegIMAEncoder.swift`). Reading one of those
/// blocks the other way round drops a tone from 29 dB to 7 dB, which is the
/// two-to-one majority among the implementations as well.
public enum ADPCMNibbleOrder: String, Sendable, CaseIterable {
    /// Earlier sample in the low nibble. Standard IMA/DVI-4 and the default.
    case lowNibbleFirst
    /// Earlier sample in the high nibble. Only `neolink.net` writes this.
    case highNibbleFirst
}

/// IMA/DVI-4 ADPCM, in the block shape the Baichuan talk channel asks for.
///
/// One block is `samplesPerBlock` samples: a 4-byte DVI state header followed by
/// one 4-bit code per sample, two to a byte. At the measured
/// `lengthPerEncoder` of 1024 that is 4 + 512 = 516 bytes.
///
/// This is not the IMA WAV block layout. IMA WAV puts the first sample of the
/// block in the header and codes only the rest, so a 516-byte block would hold
/// 1025 samples. The device asks for `lengthPerEncoder` samples in
/// `lengthPerEncoder / 2` bytes, so every sample here is coded as a nibble and
/// the header carries the running state instead. `neolink`
/// (`bc_protocol/talk.rs`) derives the same sizes.
///
/// State runs across blocks inside one session. The header re-seeds the decoder
/// at every block, so a lost block costs one block of audio, not the rest of the
/// utterance. Call ``reset()`` between sessions.
///
/// The predictor is advanced with the decoder's own arithmetic, not with a
/// separate encoder-side formula. That keeps the value written into each block
/// header equal to the value the decoder already holds; an encoder that drifts
/// would make the decoder jump at every block boundary, 15.6 times a second at
/// 1024 samples and 16000 Hz. `neolink.net` (`Adpcm.cs`, `EncodeBlock`) makes
/// the same choice. ffmpeg does not, which is why its bytes are close to these
/// but not identical.
public struct IMAADPCMEncoder: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .unsupportedFormat(let why): "unsupported ADPCM format: \(why)"
            }
        }
    }

    public let format: TalkAudioFormat
    public let nibbleOrder: ADPCMNibbleOrder

    /// Bytes in one encoded block, DVI state header included.
    public var blockSize: Int { 4 + format.samplesPerBlock / 2 }

    /// Samples held back because they do not fill a block yet.
    public var bufferedSampleCount: Int { pending.count }

    private var predictor: Int32 = 0
    private var stepIndex: Int32 = 0
    private var pending: [Int16] = []

    public init(
        format: TalkAudioFormat = TalkAudioFormat(),
        nibbleOrder: ADPCMNibbleOrder = .lowNibbleFirst
    ) throws {
        guard format.channels == 1 else {
            throw Failure.unsupportedFormat("\(format.channels) channels, only mono is coded")
        }
        guard format.samplePrecision == 16 else {
            throw Failure.unsupportedFormat("\(format.samplePrecision)-bit input, only 16-bit is coded")
        }
        guard format.sampleRate > 0 else {
            throw Failure.unsupportedFormat("sample rate \(format.sampleRate)")
        }
        guard format.samplesPerBlock > 0, format.samplesPerBlock.isMultiple(of: 2) else {
            throw Failure.unsupportedFormat("\(format.samplesPerBlock) samples per block, must be even and positive")
        }
        self.format = format
        self.nibbleOrder = nibbleOrder
    }

    /// Codes as many whole blocks as `samples` completes. A remainder waits for
    /// the next call, or for ``finish()``.
    public mutating func encode(_ samples: [Int16]) -> [Data] {
        pending.append(contentsOf: samples)
        let count = format.samplesPerBlock
        var blocks: [Data] = []
        var consumed = 0
        while pending.count - consumed >= count {
            blocks.append(encodeBlock(pending[consumed ..< consumed + count]))
            consumed += count
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        return blocks
    }

    /// Codes the buffered remainder as one block, padded to full length with
    /// silence. Returns nil when nothing is buffered.
    public mutating func finish() -> Data? {
        guard !pending.isEmpty else { return nil }
        var tail = pending
        tail.append(contentsOf: repeatElement(0, count: format.samplesPerBlock - tail.count))
        pending.removeAll(keepingCapacity: true)
        return encodeBlock(tail[...])
    }

    /// Drops the buffered samples and the predictor state. Use between sessions.
    public mutating func reset() {
        predictor = 0
        stepIndex = 0
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func encodeBlock(_ samples: ArraySlice<Int16>) -> Data {
        var out = Data(capacity: blockSize)
        // The DVI state header is the decoder's seed for this block: the predictor
        // and step index as they stand *before* the first coded sample, so both
        // sides run the same arithmetic from the same point.
        let seed = UInt16(bitPattern: Int16(predictor))
        out.append(UInt8(seed & 0xff))
        out.append(UInt8(seed >> 8))
        out.append(UInt8(stepIndex))
        out.append(0)  // reserved, always zero

        var index = samples.startIndex
        while index < samples.endIndex {
            let first = compress(samples[index])
            let second = compress(samples[index + 1])
            switch nibbleOrder {
            case .lowNibbleFirst: out.append(first | (second << 4))
            case .highNibbleFirst: out.append((first << 4) | second)
            }
            index += 2
        }
        return out
    }

    /// One sample to one 4-bit code, advancing the state the way the decoder
    /// will. Textbook IMA; the same arithmetic as ffmpeg's
    /// `adpcm_ima_compress_sample`.
    private mutating func compress(_ sample: Int16) -> UInt8 {
        var delta = Int32(sample) - predictor
        var step = Self.stepTable[Int(stepIndex)]
        var code: UInt8 = delta < 0 ? 8 : 0
        if delta < 0 { delta = -delta }

        var diff = delta + (step >> 3)
        if delta >= step {
            code |= 4
            delta -= step
        }
        step >>= 1
        if delta >= step {
            code |= 2
            delta -= step
        }
        step >>= 1
        if delta >= step {
            code |= 1
            delta -= step
        }
        diff -= delta

        predictor = (code & 8) != 0 ? predictor - diff : predictor + diff
        predictor = min(max(predictor, -32768), 32767)
        stepIndex = min(max(stepIndex + Self.indexTable[Int(code)], 0), 88)
        return code
    }

    static let indexTable: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]
}
