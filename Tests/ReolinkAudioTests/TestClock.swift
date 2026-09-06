import Foundation

/// A clock that jumps straight to every deadline, so a minute of pacing takes
/// no time to test. It records the largest instant it ever reached, which is
/// what a drift check reads.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var current = Duration.zero
    private(set) var sleepCount = 0

    var now: Instant {
        lock.withLock { Instant(offset: current) }
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            sleepCount += 1
            if deadline.offset > current { current = deadline.offset }
        }
    }
}
