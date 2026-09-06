import Foundation

extension TalkAbility {
    /// `FDX` is the only duplex any source has ever seen in `duplexList`, and
    /// it is what channel 0 reports here. The list is read anyway.
    public var preferredDuplex: String {
        duplexes.contains("FDX") ? "FDX" : (duplexes.first ?? "FDX")
    }

    /// The format to hand an encoder.
    ///
    /// `lengthPerEncoder` counts samples, not bytes: 1024 samples is 512 bytes
    /// of packed nibbles, which is 64 ms at 16 kHz.
    public var audioFormat: TalkAudioFormat {
        TalkAudioFormat(
            sampleRate: sampleRate,
            samplePrecision: samplePrecision,
            channels: soundTrack.lowercased() == "mono" ? 1 : 2,
            samplesPerBlock: lengthPerEncoder
        )
    }

    /// Bytes in one complete block on the wire: the packed nibbles plus the
    /// four byte DVI state header.
    public var fullBlockSize: Int {
        BcMedia.fullBlockSize(lengthPerEncoder: lengthPerEncoder)
    }

    /// The device refuses anything but ADPCM for talk.
    public var isTalkable: Bool { audioType.lowercased() == "adpcm" }
}
