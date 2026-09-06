import Foundation

/// Wall-clock pacing for a talk stream.
///
/// The camera plays what it is given at the rate it asked for. Send faster and
/// the device buffers or drops; send slower and the speaker stutters. One block
/// of 1024 samples at 16000 Hz is 64 ms.
///
/// Every deadline is measured from one fixed origin and an integer count of
/// samples, so a long utterance cannot accumulate error. Adding 64 ms per block
/// in a loop would.
public struct AudioPacer<C: Clock>: Sendable where C.Duration == Duration, C.Instant: Sendable {
    public let format: TalkAudioFormat
    public let clock: C

    /// Samples handed out so far.
    public private(set) var samplesSent = 0

    private var origin: C.Instant?

    public init(format: TalkAudioFormat = TalkAudioFormat(), clock: C = ContinuousClock()) {
        self.format = format
        self.clock = clock
    }

    /// How long one full block plays for.
    public var blockDuration: Duration { playbackOffset(forSamples: format.samplesPerBlock) }

    /// Time from the start of the stream at which `samples` samples have played.
    ///
    /// Integer nanoseconds, computed from the total. The error against the exact
    /// value is under one nanosecond and never accumulates.
    public func playbackOffset(forSamples samples: Int) -> Duration {
        .nanoseconds(samples * 1_000_000_000 / format.sampleRate)
    }

    /// Total playing time of everything handed out so far.
    public var elapsedPlayback: Duration { playbackOffset(forSamples: samplesSent) }

    /// Suspends until the audio already handed out has played, then counts
    /// `samples` more as sent. The first call returns at once and starts the
    /// clock.
    public mutating func waitForSlot(samples: Int) async throws {
        guard let start = origin else {
            origin = clock.now
            samplesSent = samples
            return
        }
        try await clock.sleep(until: start.advanced(by: elapsedPlayback), tolerance: nil)
        samplesSent += samples
    }

    /// Suspends until everything handed out has played, plus `extra`.
    ///
    /// `neolink`'s `talk_stream` waits like this before it releases the talk
    /// slot; releasing early cuts off audio the device has not played yet.
    public mutating func waitForPlayout(extra: Duration = .milliseconds(100)) async throws {
        guard let start = origin else { return }
        try await clock.sleep(until: start.advanced(by: elapsedPlayback + extra), tolerance: nil)
    }

    /// Forgets the origin and the sample count. The next ``waitForSlot(samples:)``
    /// starts a new stream.
    public mutating func reset() {
        origin = nil
        samplesSent = 0
    }
}
