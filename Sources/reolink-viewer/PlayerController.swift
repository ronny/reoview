import Foundation
import Observation
import ReolinkNVR
import ReolinkVideo

/// What one tile shows about its stream.
enum TileState: Equatable, Sendable {
    case connecting
    case playing
    case retrying(attempt: Int)
    case failed(String)
}

/// One tile's state machine.
///
/// Per ADR 0001 everything engine-independent lives here: the walk through the
/// candidate URLs, the reconnect backoff, and the mute state. The `VideoPlayer`
/// only opens a URL and reports what happened.
@MainActor
@Observable
final class PlayerController {
    /// 2 s, 5 s, then 10 s for every attempt after that.
    static let backoff: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]

    let source: StreamSource
    let title: String

    private(set) var state: TileState = .connecting
    private(set) var isMuted: Bool

    /// Reports the candidate that actually played, so `AppState` can put it
    /// first next time.
    @ObservationIgnored var onWinningURL: (@MainActor (StreamSource, URL) -> Void)?

    /// Exposed so `VideoPlayerView` can host its view. Nothing outside
    /// this type should drive it.
    @ObservationIgnored let player: any VideoPlayer
    @ObservationIgnored private var candidates: [URL]
    @ObservationIgnored private var candidateIndex = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var expectsStop = false
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(
        source: StreamSource,
        title: String,
        player: any VideoPlayer,
        candidates: [URL],
        muted: Bool = true
    ) {
        self.source = source
        self.title = title
        self.player = player
        self.candidates = candidates
        self.isMuted = muted
        player.setMuted(muted)
        observePlayer()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attempt = 0
        candidateIndex = 0
        open()
    }

    /// Full stop, not a pause. ADR 0009: sleep must free the RTSP session.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        expectsStop = true
        player.stop()
        state = .connecting
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.setMuted(muted)
    }

    func setCandidates(_ urls: [URL]) {
        candidates = urls
        candidateIndex = 0
        attempt = 0
        guard isRunning else { return }
        expectsStop = true
        player.stop()
        open()
    }

    private func observePlayer() {
        let states = player.states
        stateTask = Task { [weak self] in
            for await playerState in states {
                guard let self else { return }
                self.handle(playerState)
            }
        }
    }

    private func handle(_ playerState: VideoPlayerState) {
        switch playerState {
        case .idle:
            break
        case .opening:
            expectsStop = false
            if attempt == 0 { state = .connecting }
        case .playing:
            expectsStop = false
            attempt = 0
            state = .playing
            if let url = candidates[safe: candidateIndex] {
                onWinningURL?(source, url)
            }
        case .stopped:
            if expectsStop {
                expectsStop = false
                return
            }
            scheduleRetry(message: "The stream ended")
        case .failed(let message):
            expectsStop = false
            scheduleRetry(message: message)
        }
    }

    private func scheduleRetry(message: String) {
        guard isRunning else { return }

        attempt += 1
        if !candidates.isEmpty {
            candidateIndex = (candidateIndex + 1) % candidates.count
        }

        // Every candidate has now failed at least once, so the tile is a real
        // failure rather than a codec guess that missed.
        state = attempt < max(candidates.count, 1) ? .retrying(attempt: attempt) : .failed(message)

        let delay = Self.backoff[min(attempt - 1, Self.backoff.count - 1)]
        Log.player.info(
            "\(self.source.id, privacy: .public) retry \(self.attempt, privacy: .public) in \(delay, privacy: .public): \(message, privacy: .public)"
        )

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.open()
        }
    }

    private func open() {
        guard let url = candidates[safe: candidateIndex] else {
            state = .failed("No stream URL for this camera")
            return
        }
        if attempt == 0 { state = .connecting }
        expectsStop = false
        player.setMuted(isMuted)
        player.play(url: url)
    }
}
