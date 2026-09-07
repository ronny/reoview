import AVFoundation
import AppKit
import Foundation
import Observation
import ReolinkAudio
import ReolinkBaichuan
import ReolinkNVR

/// What the app is doing with the camera's speaker right now.
///
/// `listening` is the push-to-talk case: the Mac microphone is open and on air.
/// `speaking` is a stored phrase read out by the speech synthesiser.
enum TalkActivity: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case speaking(String)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .connecting, .listening, .speaking: true
        case .idle, .failed: false
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .listening: "Talking"
        case .speaking: "Speaking"
        case .failed: "Failed"
        }
    }
}

enum TalkError: LocalizedError, Equatable {
    case notConfigured
    case noPassword
    case noMicrophone
    case microphoneDenied
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No NVR is configured."
        case .noPassword: "No password is saved for the NVR."
        case .noMicrophone: "This Mac has no audio input device."
        case .microphoneDenied:
            "ReoView is not allowed to use the microphone. "
                + "Turn it on in System Settings, Privacy and Security, Microphone."
        case .notSupported(let name): "\(name) does not accept two-way talk."
        }
    }
}

/// Two-way talk, over Baichuan on port 9000.
///
/// One session at a time, for the whole app. Every job — a held push-to-talk
/// button or a spoken phrase — runs inside ``runner``, and a new job cancels
/// the one before it and then *waits for it*, so the camera's talk slot is
/// released before the next one asks for it. The camera grants that slot to one
/// client, and a slot left open holds its audio path against everything else.
///
/// The connection is opened on the first press and dropped again after
/// ``idleTimeout``. It is deliberately not opened at launch: the NVR rations
/// concurrent sessions and this app already holds one RTSP stream per tile and
/// an HTTP session.
///
/// Nothing here logs the password.
@MainActor
@Observable
final class TalkController {
    /// How long a quiet connection is kept before it is given back.
    static let idleTimeout = Duration.seconds(45)

    private(set) var activity: TalkActivity = .idle

    /// The `Camera.id` the current job is talking to, so one tile can show the
    /// indicator and the others cannot.
    private(set) var activeCameraID: String?

    private(set) var isPushToTalkHeld = false

    /// A refused talk borrows the one global banner, the same as a refused
    /// control command.
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?
    @ObservationIgnored var onSuccess: (@MainActor () -> Void)?

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private var capabilities: Capabilities?

    @ObservationIgnored private var client: BaichuanClient?
    @ObservationIgnored private var deviceInfo: BaichuanDeviceInfo?
    @ObservationIgnored private var abilityByChannel: [Int: TalkAbility] = [:]

    /// The one open talk slot. Never assigned while another is still open; see
    /// ``start(_:)``.
    @ObservationIgnored private var session: (any TalkSession)?

    /// The source feeding the open session, so a released button can finish it
    /// cleanly rather than cut it off.
    @ObservationIgnored private var activeSource: (any PCMSource)?

    @ObservationIgnored private var runner: Task<Void, Never>?

    /// Which job owns the observable state. A cancelled job unwinds after its
    /// replacement has already started, and must not write `idle` over it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var mouseUpMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    init(config: ConfigStore) {
        self.config = config
    }

    // MARK: - What the camera offers

    /// Told once, when the camera list is discovered.
    func setCapabilities(_ capabilities: Capabilities?) {
        self.capabilities = capabilities
    }

    /// Whether this channel takes talk at all.
    ///
    /// `GetAbility` answers this over the HTTP session the app already holds,
    /// so the grid can decide before anything opens port 9000. The Baichuan
    /// `Support` response says the same thing as `ipcAudioTalk`, and it is
    /// checked again once a connection exists.
    func isAvailable(for camera: Camera) -> Bool {
        guard !config.config.host.isEmpty, !config.config.username.isEmpty else { return false }
        return capabilities?.supports("talk", channel: camera.channel) ?? false
    }

    /// A half-edited phrase in Settings is an empty string. It is not offered.
    var phrases: [String] {
        config.config.talkPhrases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func isActive(cameraID: String) -> Bool {
        activeCameraID == cameraID && activity.isRunning
    }

    // MARK: - Push to talk

    /// The press half. The session stays open until ``stopPushToTalk()``, a
    /// lost mouse-up, the app resigning active, or a failure.
    func startPushToTalk(to camera: Camera) {
        guard !isPushToTalkHeld else { return }
        isPushToTalkHeld = true
        start(.microphone, target: Target(camera))
    }

    /// The release half. Safe to call when nothing is held.
    ///
    /// The source is finished rather than the task cancelled, so the encoder's
    /// remainder and the pacer's playout wait both still run: cancelling here
    /// would clip the last block off the end.
    func stopPushToTalk() {
        guard isPushToTalkHeld else { return }
        isPushToTalkHeld = false
        if case .listening = activity, let activeSource {
            activeSource.stop()
        } else {
            // The button was released before the microphone went on air.
            // Nothing has been sent, so there is nothing to drain, and
            // `perform` checks the flag again before it opens a session.
            runner?.cancel()
        }
    }

    // MARK: - Phrases

    /// Speaks one phrase through the camera's speaker.
    ///
    /// There is no way to upload a clip to the camera, so the phrase is
    /// synthesised on the Mac and pushed down the live talk channel.
    func speak(_ phrase: String, to camera: Camera) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A phrase never takes over from a held button: the person holding it
        // is mid-sentence.
        guard !isPushToTalkHeld else { return }
        start(.phrase(trimmed), target: Target(camera))
    }

    // MARK: - Stopping

    /// The visible stop control, and every path that takes the tile away.
    func stop() {
        isPushToTalkHeld = false
        runner?.cancel()
    }

    /// Waits for the session to be released and gives the connection back.
    /// `AppState.teardown()` and quit both go through here.
    func shutdown() async {
        stop()
        await runner?.value
        runner = nil
        idleTask?.cancel()
        idleTask = nil
        stopWatchingForLostRelease()
        await disconnectClient()
        activity = .idle
        activeCameraID = nil
    }

    // MARK: - Running one job

    private struct Target: Equatable {
        let cameraID: String
        let name: String
        let channel: Int

        init(_ camera: Camera) {
            cameraID = camera.id
            name = camera.name
            channel = camera.channel
        }
    }

    private enum Job {
        case microphone
        case phrase(String)

        var isMicrophone: Bool {
            if case .microphone = self { return true }
            return false
        }
    }

    /// Cancels whatever is running and queues this job behind its release.
    ///
    /// The wait is the whole point. The camera grants one talk slot, so a
    /// second `TalkConfig` sent before the first slot is released is refused,
    /// and a session left open holds the camera's audio path. Pressing
    /// push-to-talk during a phrase therefore cancels the phrase rather than
    /// opening a session beside it.
    private func start(_ job: Job, target: Target) {
        let previous = runner
        previous?.cancel()
        generation += 1
        let generation = generation
        activity = .connecting
        activeCameraID = target.cameraID
        watchForLostRelease()

        runner = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.run(job, target: target, generation: generation)
        }
    }

    private func run(_ job: Job, target: Target, generation: Int) async {
        var failure: (any Error)?
        do {
            try await perform(job, target: target, generation: generation)
        } catch is CancellationError {
            // A released button, or a phrase overtaken by a press. Not a fault.
        } catch {
            failure = error
        }

        // Every exit runs the same release. There is no path out of a talk job
        // that leaves the slot open.
        activeSource?.stop()
        activeSource = nil
        await releaseSession()

        // A job that has already been replaced keeps its hands off the state
        // and the monitors: the job that replaced it owns both now.
        let isCurrent = generation == self.generation
        if isCurrent {
            stopWatchingForLostRelease()
            activeCameraID = nil
        }

        if let failure {
            let message = Self.describe(failure)
            Log.talk.error("talk failed: \(message, privacy: .public)")
            // A failed command can leave the connection half open, and the
            // client only learns that by timing the next one out. Start fresh.
            await disconnectClient()
            guard isCurrent else { return }
            activity = .failed(message)
            onFailure?("Talk to \(target.name): \(message)")
        } else {
            guard isCurrent else { return }
            activity = .idle
            onSuccess?()
            scheduleIdleDisconnect()
        }
    }

    private func perform(_ job: Job, target: Target, generation: Int) async throws {
        try Task.checkCancellation()
        if job.isMicrophone { try await ensureMicrophoneAccess() }

        let client = try await connectedClient()
        let info = try await supportReport(from: client)
        guard info.supportsTalk(channel: target.channel) else {
            throw TalkError.notSupported(target.name)
        }
        let ability = try await talkAbility(from: client, channel: target.channel)
        let format = ability.encoderFormat

        try Task.checkCancellation()
        // The press can end while the connection is still coming up. Opening a
        // session for it now would leave one nobody is holding.
        if job.isMicrophone, !isPushToTalkHeld { return }

        let source: any PCMSource = switch job {
        case .microphone: MicrophoneSource(format: format)
        case .phrase(let text): SpeechSource(text: text, format: format)
        }

        var encoder = try IMAADPCMEncoder(format: format)
        var pacer = AudioPacer(format: format)

        let session = try await client.startTalk(channel: target.channel, ability: ability)
        self.session = session
        activeSource = source
        if generation == self.generation {
            activity = job.isMicrophone ? .listening : .speaking(phraseText(of: job))
        }

        for try await samples in source.samples() {
            for block in encoder.encode(samples) {
                try await pacer.waitForSlot(samples: format.samplesPerBlock)
                try await session.send(block: block)
            }
        }
        // The device plays from its own buffer, so the last word is clipped
        // unless it is given something after it. Measured against the doorbell:
        // 100 ms of playout wait cut "parcel" in half, and this does not.
        for block in encoder.encode(Self.trailingSilence(format)) {
            try await pacer.waitForSlot(samples: format.samplesPerBlock)
            try await session.send(block: block)
        }
        if let tail = encoder.finish() {
            try await pacer.waitForSlot(samples: format.samplesPerBlock)
            try await session.send(block: tail)
        }
        try await pacer.waitForPlayout(extra: Self.playoutTail)
    }

    /// Silence appended after a phrase, so the device has something to play
    /// while it catches up.
    private static func trailingSilence(_ format: ReolinkAudio.TalkAudioFormat) -> [Int16] {
        [Int16](repeating: 0, count: format.sampleRate * 400 / 1000)
    }

    /// How long to hold the talk slot open after the last block.
    private static let playoutTail: Duration = .milliseconds(800)

    /// `ReolinkAudio` reports through `CustomStringConvertible` rather than
    /// `LocalizedError`, and `localizedDescription` on one of those reads as
    /// "The operation couldn't be completed", which tells the user nothing.
    private static func describe(_ error: any Error) -> String {
        if error is any LocalizedError { return error.localizedDescription }
        return String(describing: error)
    }

    private func phraseText(of job: Job) -> String {
        if case .phrase(let text) = job { return text }
        return ""
    }

    /// Idempotent: the reference is dropped before the release is awaited, so
    /// a second caller has nothing to release.
    private func releaseSession() async {
        guard let session else { return }
        self.session = nil
        await session.stop()
    }

    // MARK: - The connection

    /// Opens port 9000 on first use, and keeps it only while it is being used.
    private func connectedClient() async throws -> BaichuanClient {
        idleTask?.cancel()
        idleTask = nil
        if let client { return client }

        let host = config.config.host
        let user = config.config.username
        guard !host.isEmpty, !user.isEmpty else { throw TalkError.notConfigured }
        guard let password = try KeychainStore.password(username: user, host: host) else {
            throw TalkError.noPassword
        }

        let client = BaichuanClient(
            connection: NetworkConnection(host: host),
            credentials: BaichuanCredentials(user: user, password: password)
        )
        try await client.connect()
        self.client = client
        Log.talk.info("connected to \(host, privacy: .public) on port 9000")
        return client
    }

    private func supportReport(from client: BaichuanClient) async throws -> BaichuanDeviceInfo {
        if let deviceInfo { return deviceInfo }
        let info = try await client.deviceInfo()
        deviceInfo = info
        return info
    }

    private func talkAbility(from client: BaichuanClient, channel: Int) async throws -> TalkAbility {
        if let cached = abilityByChannel[channel] { return cached }
        let ability = try await client.talkAbility(channel: channel)
        abilityByChannel[channel] = ability
        return ability
    }

    private func scheduleIdleDisconnect() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.disconnectClient()
        }
    }

    /// `BaichuanClient.disconnect()` releases every talk slot it knows about
    /// before it logs out, so this is also a backstop for the release above.
    private func disconnectClient() async {
        idleTask?.cancel()
        idleTask = nil
        guard let client else { return }
        self.client = nil
        deviceInfo = nil
        abilityByChannel = [:]
        await client.disconnect()
        Log.talk.info("released the Baichuan connection")
    }

    // MARK: - Microphone permission

    /// Asked for before the session opens, so the camera's audio path is not
    /// held while a permission prompt sits on screen. A refusal only stops
    /// push-to-talk; the phrases do not touch the microphone.
    private func ensureMicrophoneAccess() async throws {
        guard MicrophoneSource.hasInputDevice() else { throw TalkError.noMicrophone }
        switch MicrophoneSource.authorization {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw TalkError.microphoneDenied }
        default:
            throw TalkError.microphoneDenied
        }
    }

    // MARK: - Releases the gesture never sees

    /// The same discipline as the PTZ pad. A mouse-up outside the button, or
    /// the app losing focus mid-press, never reaches the gesture that started
    /// the press, and a talk session left open holds the camera's audio path.
    ///
    /// Resigning active stops a phrase as well as a held button: an app that is
    /// not in front is not being watched, and the camera's speaker is a room
    /// the user cannot see.
    private func watchForLostRelease() {
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                MainActor.assumeIsolated { self.stopPushToTalk() }
                return event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { self.stop() }
            }
        }
    }

    private func stopWatchingForLostRelease() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

private extension TalkAbility {
    /// `ReolinkBaichuan` and `ReolinkAudio` each carry their own copy of the
    /// talk format so that neither target has to depend on the other. This is
    /// the one place the two meet.
    var encoderFormat: ReolinkAudio.TalkAudioFormat {
        let device = audioFormat
        return ReolinkAudio.TalkAudioFormat(
            sampleRate: device.sampleRate,
            samplePrecision: device.samplePrecision,
            channels: device.channels,
            samplesPerBlock: device.samplesPerBlock
        )
    }
}
