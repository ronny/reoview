import Foundation

/// What the device says it accepts, from message id 10.
public struct TalkAbility: Sendable, Equatable {
    public var duplexes: [String]
    public var audioStreamModes: [String]
    public var audioType: String
    public var sampleRate: Int
    public var samplePrecision: Int
    public var soundTrack: String
    public var lengthPerEncoder: Int

    public init(
        duplexes: [String], audioStreamModes: [String], audioType: String,
        sampleRate: Int, samplePrecision: Int, soundTrack: String, lengthPerEncoder: Int
    ) {
        self.duplexes = duplexes
        self.audioStreamModes = audioStreamModes
        self.audioType = audioType
        self.sampleRate = sampleRate
        self.samplePrecision = samplePrecision
        self.soundTrack = soundTrack
        self.lengthPerEncoder = lengthPerEncoder
    }

    /// `followVideoStream` is accepted but sends nothing back. Only
    /// `mixAudioStream` opens the return path. Measured 2026-09-06.
    public var preferredAudioStreamMode: String {
        audioStreamModes.contains("mixAudioStream") ? "mixAudioStream" : (audioStreamModes.first ?? "followVideoStream")
    }
}

/// Sends audio to one camera behind the NVR.
///
/// The channel is addressed the way every other command addresses it. Talk
/// through an NVR is measured to work: see docs/research/baichuan-talk.md.
public protocol TalkSession: Sendable {
    /// The format agreed with the device, from `TalkAbility`.
    var format: TalkAudioFormat { get }

    /// Sends one encoded ADPCM block. Pace these at real time.
    func send(block: Data) async throws

    /// Releases the session. Safe to call more than once.
    func stop() async
}

/// Mirrors `ReolinkAudio.TalkAudioFormat` so this target stays free of it.
public struct TalkAudioFormat: Sendable, Equatable {
    public var sampleRate: Int
    public var samplePrecision: Int
    public var channels: Int
    public var samplesPerBlock: Int

    public init(sampleRate: Int, samplePrecision: Int, channels: Int, samplesPerBlock: Int) {
        self.sampleRate = sampleRate
        self.samplePrecision = samplePrecision
        self.channels = channels
        self.samplesPerBlock = samplesPerBlock
    }
}
