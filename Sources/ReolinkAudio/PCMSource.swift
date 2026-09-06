import Foundation

/// The audio format the camera asks for in `TalkAbility`.
///
/// Measured on a Video Doorbell PoE and a TrackMix PoE, both through an
/// RLN8-410: adpcm, 16000 Hz, 16-bit, mono, 1024 samples per block. Read the
/// real values from the device rather than trusting these; the vendor tooling
/// says the rate varies by model.
public struct TalkAudioFormat: Sendable, Equatable {
    public var sampleRate: Int
    public var samplePrecision: Int
    public var channels: Int
    /// Samples per ADPCM block, the device's `lengthPerEncoder`.
    public var samplesPerBlock: Int

    public init(sampleRate: Int = 16000, samplePrecision: Int = 16, channels: Int = 1, samplesPerBlock: Int = 1024) {
        self.sampleRate = sampleRate
        self.samplePrecision = samplePrecision
        self.channels = channels
        self.samplesPerBlock = samplesPerBlock
    }
}

/// Produces 16-bit mono PCM at the rate the camera wants.
///
/// A microphone and a speech synthesiser are both sources. Nothing here knows
/// about the network.
public protocol PCMSource: Sendable {
    var format: TalkAudioFormat { get }

    /// Emits buffers until the source finishes or the task is cancelled.
    /// Each element is little-endian `Int16` samples, mono.
    func samples() -> AsyncThrowingStream<[Int16], Error>

    func stop()
}
