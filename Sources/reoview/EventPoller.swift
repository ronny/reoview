import Foundation
import ReolinkNVR

/// The single owner of the event poll.
///
/// ADR 0008: one batched POST carries `GetEvents` for every channel, so the
/// request count does not grow with the camera count. The poll stops on window
/// occlusion and on display sleep, which `PresenceMonitor` already reports.
///
/// This is a `@MainActor` type rather than an actor of its own. Every
/// collaborator is main-isolated — the store the views observe, the presence
/// signal, and `AppState` — while the only slow work, the round trip and its
/// decoding, already happens inside the `NVRClient` actor. A second actor would
/// add hops and buy nothing.
@MainActor
final class EventPoller {
    struct Channel: Sendable {
        let cameraID: String
        let name: String
        let channel: Int
    }

    /// Which command set the NVR answers. `GetAbility` does not report whether
    /// `GetEvents` exists, so the first poll doubles as the probe.
    private enum Mode {
        case unprobed
        case events
        case legacy
    }

    static let interval = Duration.milliseconds(1500)

    /// A single miss is normal on a busy NVR. The banner is for a lasting one.
    static let failuresBeforeBanner = 3

    private let client: NVRClient
    private let channels: [Channel]
    private let store: EventStatusStore
    private let notifier: VisitorNotifier
    private let onProbe: @MainActor (Bool) -> Void
    private let onLastingFailure: @MainActor (String) -> Void
    private let onRecovery: @MainActor () -> Void

    private var mode: Mode = .unprobed
    private var hasGetAiState = true
    private var task: Task<Void, Never>?
    private var isStarted = false
    private var isVisible = true
    private var consecutiveFailures = 0

    /// The visitor state of the previous poll, so a notification goes out on
    /// the false-to-true edge only. A camera missing from here has not been
    /// sampled yet; that first sample is a state snapshot, not an arrival, so
    /// it never notifies.
    private var lastVisitorByCameraID: [String: Bool] = [:]

    init(
        client: NVRClient,
        channels: [Channel],
        store: EventStatusStore,
        notifier: VisitorNotifier,
        onProbe: @escaping @MainActor (Bool) -> Void,
        onLastingFailure: @escaping @MainActor (String) -> Void,
        onRecovery: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.channels = channels
        self.store = store
        self.notifier = notifier
        self.onProbe = onProbe
        self.onLastingFailure = onLastingFailure
        self.onRecovery = onRecovery
    }

    func start() {
        isStarted = true
        resume()
    }

    func stop() {
        isStarted = false
        suspend()
    }

    /// The presence signal from `PresenceMonitor`. Nothing is polled while the
    /// window is hidden or the display is asleep.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { resume() } else { suspend() }
    }

    private func resume() {
        guard isStarted, isVisible, task == nil, !channels.isEmpty else { return }
        task = Task { [weak self] in await self?.run() }
    }

    private func suspend() {
        task?.cancel()
        task = nil
    }

    /// Sleeps between polls rather than on a timer, so a slow NVR delays the
    /// next poll instead of queueing a backlog of them. One request is in
    /// flight at a time by construction.
    private func run() async {
        while !Task.isCancelled {
            await pollOnce()
            do {
                try await Task.sleep(for: Self.interval)
            } catch {
                return
            }
        }
    }

    private func pollOnce() async {
        do {
            switch mode {
            case .unprobed: try await probeAndPoll()
            case .events: try await pollEvents()
            case .legacy: try await pollLegacy()
            }
            noteSuccess()
        } catch {
            // A poll cut short by `stop()` is not a failure of the NVR.
            guard !Task.isCancelled else { return }
            noteFailure(error)
        }
    }

    // MARK: - Probing

    /// `reolink_aio` finds `GetEvents` by sending it once and looking for a
    /// response element that is not an error, so the probe is just the first
    /// poll. Its result is recorded on `Capabilities` through `onProbe`.
    private func probeAndPoll() async throws {
        do {
            try await pollEvents()
            mode = .events
            onProbe(true)
            Log.events.info("GetEvents is present")
        } catch let error where Self.isMissingCommand(error) {
            mode = .legacy
            onProbe(false)
            Log.events.info("GetEvents is absent, falling back to GetMdState and GetAiState")
            try await pollLegacy()
        }
    }

    /// An answer that is not an error means the command exists. A refusal from
    /// the NVR, or a body this app cannot read, both mean it is unusable. A
    /// transport failure says nothing either way, so it leaves the probe open
    /// and the next poll tries `GetEvents` again.
    private static func isMissingCommand(_ error: any Error) -> Bool {
        guard let error = error as? ReolinkError else { return false }
        switch error {
        case let .api(_, rspCode, _): return rspCode != ReolinkError.badTokenCode
        case .decoding: return true
        case .transport, .httpStatus, .authentication: return false
        }
    }

    // MARK: - Polling

    private func pollEvents() async throws {
        let responses = try await client.send(channels.map { (command: GetEvents(), channel: $0.channel) })
        try Task.checkCancellation()
        apply(zip(channels, responses).map { ($0, EventStatusStore.CameraEvents(events: $1)) })
    }

    /// `NVRClient.send` batches one command type per POST, so the fallback pair
    /// is two round trips rather than one.
    private func pollLegacy() async throws {
        let motion = try await client.send(channels.map { (command: GetMdState(), channel: $0.channel) })

        var ai: [GetAiState.Response] = []
        if hasGetAiState {
            do {
                ai = try await client.send(channels.map { (command: GetAiState(), channel: $0.channel) })
            } catch let error where Self.isMissingCommand(error) {
                hasGetAiState = false
                Log.events.info("GetAiState is absent, motion only")
            }
        }

        try Task.checkCancellation()
        apply(channels.enumerated().compactMap { index, channel in
            guard let motion = motion[safe: index] else { return nil }
            return (channel, EventStatusStore.CameraEvents(motion: motion, ai: ai[safe: index]))
        })
    }

    private func apply(_ updates: [(Channel, EventStatusStore.CameraEvents)]) {
        for (channel, events) in updates {
            let visitor = events.isActive(.visitor)
            if visitor, lastVisitorByCameraID[channel.cameraID] == false {
                notifier.visitorArrived(cameraName: channel.name)
            }
            lastVisitorByCameraID[channel.cameraID] = visitor
            store.update(cameraID: channel.cameraID, events: events)
        }
    }

    // MARK: - Failures

    /// A failed poll never stops the loop. It only reaches the banner once it
    /// has lasted.
    private func noteFailure(_ error: any Error) {
        consecutiveFailures += 1
        Log.events.error("event poll failed: \(error.localizedDescription, privacy: .public)")
        guard consecutiveFailures == Self.failuresBeforeBanner else { return }
        onLastingFailure(error.localizedDescription)
    }

    private func noteSuccess() {
        let wasFailing = consecutiveFailures >= Self.failuresBeforeBanner
        consecutiveFailures = 0
        if wasFailing { onRecovery() }
    }
}
