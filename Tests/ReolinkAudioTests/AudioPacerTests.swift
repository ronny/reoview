import Foundation
import Testing
@testable import ReolinkAudio

@Suite("Audio pacer")
struct AudioPacerTests {
    @Test("One block of 1024 samples at 16000 Hz is 64 ms")
    func blockDuration() {
        let pacer = AudioPacer(format: TalkAudioFormat(), clock: TestClock())
        #expect(pacer.blockDuration == .milliseconds(64))
        #expect(pacer.playbackOffset(forSamples: 16_000) == .seconds(1))
        #expect(pacer.playbackOffset(forSamples: 0) == .zero)
    }

    @Test("Offsets are computed from the total, so a minute cannot drift")
    func offsetsDoNotAccumulateError() {
        let pacer = AudioPacer(format: TalkAudioFormat(), clock: TestClock())
        // 937 blocks of 64 ms is 59.968 s, the closest whole block to a minute.
        for block in 0 ... 937 {
            #expect(pacer.playbackOffset(forSamples: block * 1024) == .milliseconds(block * 64))
        }
    }

    @Test("A rate that does not divide evenly stays inside a microsecond over a minute")
    func awkwardSampleRate() {
        let format = TalkAudioFormat(sampleRate: 44_100, samplesPerBlock: 1024)
        let pacer = AudioPacer(format: format, clock: TestClock())
        let samples = 44_100 * 60
        let offset = pacer.playbackOffset(forSamples: samples)
        #expect(offset == .seconds(60))

        // Every intermediate deadline is within a nanosecond of the true time.
        for block in stride(from: 0, through: samples, by: 1024) {
            let exact = Double(block) / 44_100.0
            let seconds = Double(offset: pacer.playbackOffset(forSamples: block))
            #expect(abs(seconds - exact) < 1e-9)
        }
    }

    @Test("A simulated minute of blocks lands on the exact play-out time")
    func aSimulatedMinuteDoesNotDrift() async throws {
        let clock = TestClock()
        var pacer = AudioPacer(format: TalkAudioFormat(), clock: clock)
        let start = clock.now

        for _ in 0 ..< 937 {
            try await pacer.waitForSlot(samples: 1024)
        }

        #expect(pacer.samplesSent == 937 * 1024)
        // The last block goes out at the start of its own slot, so the clock has
        // moved by 936 slots, not 937.
        #expect(start.duration(to: clock.now) == .milliseconds(936 * 64))
        #expect(pacer.elapsedPlayback == .milliseconds(937 * 64))

        try await pacer.waitForPlayout()
        #expect(start.duration(to: clock.now) == .milliseconds(937 * 64) + .milliseconds(100))
    }

    @Test("The first block goes out at once")
    func firstBlockIsImmediate() async throws {
        let clock = TestClock()
        var pacer = AudioPacer(format: TalkAudioFormat(), clock: clock)

        try await pacer.waitForSlot(samples: 1024)
        #expect(clock.now.offset == .zero)
        #expect(clock.sleepCount == 0)

        try await pacer.waitForSlot(samples: 1024)
        #expect(clock.now.offset == .milliseconds(64))
    }

    @Test("Short blocks are paced by their own length")
    func partialBlocksArePacedByLength() async throws {
        let clock = TestClock()
        var pacer = AudioPacer(format: TalkAudioFormat(), clock: clock)

        try await pacer.waitForSlot(samples: 1024)
        try await pacer.waitForSlot(samples: 160)  // 10 ms
        #expect(clock.now.offset == .milliseconds(64))
        try await pacer.waitForSlot(samples: 1024)
        #expect(clock.now.offset == .milliseconds(74))
    }

    @Test("reset() starts a new stream")
    func resetStartsAgain() async throws {
        let clock = TestClock()
        var pacer = AudioPacer(format: TalkAudioFormat(), clock: clock)
        try await pacer.waitForSlot(samples: 1024)
        try await pacer.waitForSlot(samples: 1024)

        pacer.reset()
        #expect(pacer.samplesSent == 0)
        let resumed = clock.now
        try await pacer.waitForSlot(samples: 1024)
        #expect(clock.now == resumed)
    }

    @Test("Cancellation stops the pacer")
    func cancellation() async throws {
        let clock = TestClock()
        let task = Task {
            var pacer = AudioPacer(format: TalkAudioFormat(), clock: clock)
            try await pacer.waitForSlot(samples: 1024)
            while true {
                try await pacer.waitForSlot(samples: 1024)
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private extension Double {
    init(offset: Duration) {
        let (seconds, attoseconds) = offset.components
        self = Double(seconds) + Double(attoseconds) * 1e-18
    }
}
