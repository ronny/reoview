import Foundation
import Observation
import ReolinkNVR

/// The controls of one camera, and the evidence that each one is real.
///
/// A `has*` flag stays false until the matching `Get` answered for that
/// channel. Four commands carry no `GetAbility` key at all, so the answer is
/// the only evidence they exist. See `ControlsStore.refresh()`.
struct CameraControlState {
    var floodlightOn = false
    var hasFloodlight = false

    var recording = false
    var hasManualRecord = false

    var speakerVolume = 0
    var hasSpeakerVolume = false

    var guardHasStoredPosition = false
    var hasGuard = false

    /// No `Get` reports the siren, so this only remembers what the app sent.
    var sirenOn = false

    var autoTrackOn = false
    var hasAutoTrack = false

    /// `SetAiCfg` writes back the field that `GetAiCfg` reported.
    var autoTrackUsesSmartTrack = true

    var zoom = 0
    var zoomRange: GetZoomFocus.Bounds?

    var presets: [GetPtzPreset.Preset] = []

    var quickReplies: [GetAudioFileList.AudioFile] = []
    var selectedQuickReplyID: Int?

    var busy: Set<ControlKind> = []
}

/// One control, for the in-flight guard. A control already waiting on the NVR
/// takes no second click, so repeated clicks cannot queue up behind each other.
enum ControlKind: Hashable, Sendable {
    case floodlight
    case siren
    case manualRecord
    case autoTrack
    case guardGo
    case guardSet
    case preset
    case quickReply
}

/// Sends the newest value for a key and drops the ones it overtook.
///
/// The NVR serialises requests, so a slider that sent every value it passed
/// through would leave the user waiting on commands they have already moved
/// past. One value is in flight at a time; the last value always gets sent.
@MainActor
final class LatestValueSender {
    private let settle: Duration
    private let send: @MainActor (String, Int) async -> Void
    private var pending: [String: Int] = [:]
    private var drain: Task<Void, Never>?

    init(
        settle: Duration = .milliseconds(150),
        send: @escaping @MainActor (String, Int) async -> Void
    ) {
        self.settle = settle
        self.send = send
    }

    func submit(_ value: Int, for key: String) {
        pending[key] = value
        guard drain == nil else { return }
        let settle = settle
        drain = Task { [weak self] in
            while true {
                try? await Task.sleep(for: settle)
                guard let self, !Task.isCancelled else { return }
                guard let next = self.takeNext() else { return }
                await self.send(next.key, next.value)
            }
        }
    }

    func cancel() {
        drain?.cancel()
        drain = nil
        pending = [:]
    }

    private func takeNext() -> (key: String, value: Int)? {
        guard let first = pending.first else {
            drain = nil
            return nil
        }
        pending.removeValue(forKey: first.key)
        return (first.key, first.value)
    }
}

/// Reads and writes the camera controls.
///
/// Every command goes through the one `NVRClient` actor, which holds a single
/// request in flight. This type adds what the actor cannot: an order for the
/// PTZ pair, a single click per control, and a newest-value-wins rule for the
/// sliders.
@MainActor
@Observable
final class ControlsStore {
    private(set) var states: [String: CameraControlState] = [:]

    @ObservationIgnored private let client: NVRClient
    @ObservationIgnored private let cameras: [Camera]
    @ObservationIgnored private let capabilities: Capabilities
    @ObservationIgnored private let onProbe: @MainActor (String, Bool) -> Void
    @ObservationIgnored private let onFailure: @MainActor (String) -> Void
    @ObservationIgnored private let onSuccess: @MainActor () -> Void

    @ObservationIgnored private var camerasByID: [String: Camera] = [:]

    /// Swift actors do not serve their callers in call order, so a `Stop` sent
    /// from its own task could overtake the move it is meant to end and leave
    /// the camera turning. Every `PtzCtrl` is therefore chained behind the last
    /// one instead.
    @ObservationIgnored private var ptzChain: Task<Void, Never>?

    @ObservationIgnored private var activeMove: (cameraID: String, channel: Int)?

    /// A mouse-up outside the button, or the app losing focus mid-press, would
    /// otherwise never reach the gesture that started the move, and the camera
    /// would turn until it hit its stop.
    @ObservationIgnored private var lostRelease: LostReleaseWatcher?

    @ObservationIgnored private var zoomSender: LatestValueSender?
    @ObservationIgnored private var volumeSender: LatestValueSender?

    init(
        client: NVRClient,
        cameras: [Camera],
        capabilities: Capabilities,
        onProbe: @escaping @MainActor (String, Bool) -> Void,
        onFailure: @escaping @MainActor (String) -> Void,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.cameras = cameras
        self.capabilities = capabilities
        self.onProbe = onProbe
        self.onFailure = onFailure
        self.onSuccess = onSuccess
        camerasByID = Dictionary(cameras.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        lostRelease = LostReleaseWatcher(
            onMouseUp: { [weak self] in self?.stopMove() },
            onResignActive: { [weak self] in self?.stopMove() }
        )

        zoomSender = LatestValueSender { [weak self] cameraID, value in
            await self?.sendZoom(value, cameraID: cameraID)
        }
        volumeSender = LatestValueSender { [weak self] cameraID, value in
            await self?.sendVolume(value, cameraID: cameraID)
        }
    }

    func state(for cameraID: String) -> CameraControlState {
        states[cameraID] ?? CameraControlState()
    }

    /// Gives the token back to a camera that is still moving, and drops any
    /// slider value that has not gone out yet.
    func shutdown() {
        stopMove()
        zoomSender?.cancel()
        volumeSender?.cancel()
    }

    // MARK: - Reading the current state

    /// Reads every control of every camera once, and probes the four commands
    /// that `GetAbility` says nothing about.
    func refresh() async {
        var tallies: [String: ProbeTally] = [:]

        for camera in cameras {
            await probe(GetWhiteLed(), camera: camera, into: &tallies) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.hasFloodlight = true
                    $0.floodlightOn = response.whiteLed.isOn
                }
            }
            await probe(GetPtzGuard(), camera: camera, into: &tallies) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.hasGuard = true
                    $0.guardHasStoredPosition = response.guardPosition.hasStoredPosition
                }
            }
            await probe(GetAudioCfg(), camera: camera, into: &tallies) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.hasSpeakerVolume = true
                    $0.speakerVolume = response.audioCfg.volume ?? 0
                }
            }
            await probe(GetManualRec(), camera: camera, into: &tallies) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.hasManualRecord = true
                    $0.recording = response.rec.isRecording
                }
            }

            await readAbilityGatedControls(of: camera)
        }

        for (command, tally) in tallies {
            guard let present = tally.result else {
                Log.controls.info("probe for \(command, privacy: .public) was inconclusive")
                continue
            }
            onProbe(command, present)
        }
    }

    private func readAbilityGatedControls(of camera: Camera) async {
        let channel = camera.channel

        if capabilities.supportsPtzPresets(channel: channel) {
            await read(GetPtzPreset(), camera: camera) { [weak self] response in
                self?.mutate(camera.id) { $0.presets = response.storedPresets }
            }
        }

        if capabilities.supportsZoom(channel: channel) {
            await read(GetZoomFocus(), camera: camera) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.zoom = response.zoom
                    $0.zoomRange = response.zoomRange
                }
            }
        }

        if capabilities.supportsAutoTrack(channel: channel) {
            await read(GetAiCfg(), camera: camera) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.hasAutoTrack = true
                    $0.autoTrackOn = response.autoTrackEnabled
                    $0.autoTrackUsesSmartTrack = response.usesSmartTrack
                }
            }
        }

        if capabilities.supportsQuickReplyPlayback(channel: channel) {
            await read(GetAudioFileList(), camera: camera) { [weak self] response in
                self?.mutate(camera.id) {
                    $0.quickReplies = response.files
                    $0.selectedQuickReplyID = $0.selectedQuickReplyID ?? response.files.first?.id
                }
            }
        }

        if capabilities.supportsQuickReply(channel: channel) {
            await read(GetAutoReply(), camera: camera) { [weak self] response in
                let stored = response.autoReply.selectedFileID
                guard stored >= 0 else { return }
                self?.mutate(camera.id) {
                    if $0.quickReplies.contains(where: { $0.id == stored }) {
                        $0.selectedQuickReplyID = stored
                    }
                }
            }
        }
    }

    // MARK: - Probing

    /// What one channel's answer says about whether a command exists. A reply
    /// that is not an error is the `present` case, which no failure can be.
    private enum ProbeOutcome {
        case present
        case absent
        case inconclusive

        init(_ presence: ReolinkError.CommandPresence) {
            switch presence {
            case .absent: self = .absent
            case .inconclusive: self = .inconclusive
            }
        }
    }

    /// A command counts as present as soon as one channel answers it. It only
    /// counts as absent when every channel refused it, and a channel that could
    /// not be reached at all leaves the tally open, so a dropped connection is
    /// never mistaken for a missing feature.
    private struct ProbeTally {
        var sawPresent = false
        var sawAbsent = false
        var sawInconclusive = false

        var result: Bool? {
            if sawPresent { return true }
            if sawInconclusive { return nil }
            return sawAbsent ? false : nil
        }
    }

    private func probe<C: NVRCommand>(
        _ command: C,
        camera: Camera,
        into tallies: inout [String: ProbeTally],
        apply: @MainActor (C.Response) -> Void
    ) async {
        var tally = tallies[C.cmd] ?? ProbeTally()
        let outcome: ProbeOutcome
        do {
            apply(try await client.send(command, channel: camera.channel))
            outcome = .present
        } catch {
            outcome = ProbeOutcome(error.commandPresence)
            Log.controls.info(
                "\(C.cmd, privacy: .public) on channel \(camera.channel) failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        switch outcome {
        case .present: tally.sawPresent = true
        case .absent: tally.sawAbsent = true
        case .inconclusive: tally.sawInconclusive = true
        }
        tallies[C.cmd] = tally
    }

    private func read<C: NVRCommand>(
        _ command: C,
        camera: Camera,
        apply: @MainActor (C.Response) -> Void
    ) async {
        do {
            apply(try await client.send(command, channel: camera.channel))
        } catch {
            Log.controls.info(
                "\(C.cmd, privacy: .public) on channel \(camera.channel) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - PTZ

    /// The press half of the pad. The camera keeps moving until `stopMove()`.
    func startMove(_ direction: PtzOperation, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        if activeMove != nil { stopMove() }

        activeMove = (cameraID, camera.channel)
        lostRelease?.start()

        let speed = capabilities.supportsPtzSpeed(channel: camera.channel) ? PtzCtrl.defaultSpeed : nil
        enqueuePtz(PtzCtrl(move: direction, speed: speed), channel: camera.channel)
    }

    /// The release half. Safe to call when nothing is moving, and safe to call
    /// twice, because only the first call has a move to end.
    func stopMove() {
        guard let move = activeMove else { return }
        activeMove = nil
        lostRelease?.stop()
        enqueuePtz(PtzCtrl.stop, channel: move.channel)
    }

    /// Keeps `PtzCtrl` in the order it was asked for. A failed move does not
    /// cancel the stop that follows it.
    private func enqueuePtz(_ command: PtzCtrl, channel: Int) {
        let previous = ptzChain
        ptzChain = Task { [client] in
            await previous?.value
            do {
                _ = try await client.send(command, channel: channel)
                self.onSuccess()
            } catch {
                self.report(error)
            }
        }
    }

    func goToPreset(id: Int, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let speed = capabilities.supportsPtzSpeed(channel: camera.channel) ? PtzCtrl.defaultSpeed : nil
        perform(.preset, cameraID: cameraID, revert: { _ in }) { [client] in
            _ = try await client.send(PtzCtrl(preset: id, speed: speed), channel: camera.channel)
        }
    }

    // MARK: - Guard position

    func goToGuardPosition(cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        perform(.guardGo, cameraID: cameraID, revert: { _ in }) { [client] in
            _ = try await client.send(SetPtzGuard(channel: camera.channel, operation: .goToPosition))
        }
    }

    func setGuardPositionToCurrent(cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let hadPosition = state(for: cameraID).guardHasStoredPosition
        mutate(cameraID) { $0.guardHasStoredPosition = true }
        perform(.guardSet, cameraID: cameraID, revert: { $0.guardHasStoredPosition = hadPosition }) { [client] in
            _ = try await client.send(SetPtzGuard(channel: camera.channel, operation: .setPosition))
        }
    }

    // MARK: - Toggles

    func setFloodlight(_ on: Bool, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let previous = state(for: cameraID).floodlightOn
        mutate(cameraID) { $0.floodlightOn = on }
        perform(.floodlight, cameraID: cameraID, revert: { $0.floodlightOn = previous }) { [client] in
            _ = try await client.send(SetWhiteLed(channel: camera.channel, on: on))
        }
    }

    func setSiren(_ on: Bool, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let previous = state(for: cameraID).sirenOn
        mutate(cameraID) { $0.sirenOn = on }
        perform(.siren, cameraID: cameraID, revert: { $0.sirenOn = previous }) { [client] in
            _ = try await client.send(AudioAlarmPlay(on: on), channel: camera.channel)
        }
    }

    func setManualRecord(_ on: Bool, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let previous = state(for: cameraID).recording
        mutate(cameraID) { $0.recording = on }
        perform(.manualRecord, cameraID: cameraID, revert: { $0.recording = previous }) { [client] in
            _ = try await client.send(SetManualRec(channel: camera.channel, recording: on))
        }
    }

    func setAutoTrack(_ on: Bool, cameraID: String) {
        guard let camera = camerasByID[cameraID] else { return }
        let current = state(for: cameraID)
        let previous = current.autoTrackOn
        let command = current.autoTrackUsesSmartTrack ? SetAiCfg(smartTrack: on) : SetAiCfg(aiTrack: on)
        mutate(cameraID) { $0.autoTrackOn = on }
        perform(.autoTrack, cameraID: cameraID, revert: { $0.autoTrackOn = previous }) { [client] in
            _ = try await client.send(command, channel: camera.channel)
        }
    }

    // MARK: - Quick reply

    func selectQuickReply(id: Int, cameraID: String) {
        mutate(cameraID) { $0.selectedQuickReplyID = id }
    }

    func playQuickReply(cameraID: String) {
        guard let camera = camerasByID[cameraID],
              let fileID = state(for: cameraID).selectedQuickReplyID
        else { return }
        perform(.quickReply, cameraID: cameraID, revert: { _ in }) { [client] in
            _ = try await client.send(QuickReplyPlay(fileID: fileID), channel: camera.channel)
        }
    }

    // MARK: - Sliders

    func setZoom(_ value: Int, cameraID: String) {
        guard state(for: cameraID).zoom != value else { return }
        mutate(cameraID) { $0.zoom = value }
        zoomSender?.submit(value, for: cameraID)
    }

    func setSpeakerVolume(_ value: Int, cameraID: String) {
        guard state(for: cameraID).speakerVolume != value else { return }
        mutate(cameraID) { $0.speakerVolume = value }
        volumeSender?.submit(value, for: cameraID)
    }

    private func sendZoom(_ value: Int, cameraID: String) async {
        guard let camera = camerasByID[cameraID] else { return }
        do {
            _ = try await client.send(StartZoomFocus(channel: camera.channel, zoom: value))
            onSuccess()
        } catch {
            report(error)
        }
    }

    private func sendVolume(_ value: Int, cameraID: String) async {
        guard let camera = camerasByID[cameraID] else { return }
        do {
            _ = try await client.send(SetAudioCfg(channel: camera.channel, volume: value))
            onSuccess()
        } catch {
            report(error)
        }
    }

    // MARK: - Running one command

    /// Runs a command whose optimistic value is already in `states`. The
    /// control shows what the NVR did, not what was clicked, so a refusal puts
    /// the old value back through `revert`.
    private func perform(
        _ control: ControlKind,
        cameraID: String,
        revert: @escaping @MainActor (inout CameraControlState) -> Void,
        work: @escaping @MainActor () async throws -> Void
    ) {
        guard !state(for: cameraID).busy.contains(control) else { return }
        mutate(cameraID) { $0.busy.insert(control) }

        Task { [weak self] in
            do {
                try await work()
                self?.onSuccess()
            } catch {
                self?.mutate(cameraID, revert)
                self?.report(error)
            }
            self?.mutate(cameraID) { $0.busy.remove(control) }
        }
    }

    private func mutate(_ cameraID: String, _ change: @MainActor (inout CameraControlState) -> Void) {
        var current = states[cameraID] ?? CameraControlState()
        change(&current)
        states[cameraID] = current
    }

    private func report(_ error: any Error) {
        Log.controls.error("control command failed: \(error.localizedDescription, privacy: .public)")
        onFailure(error.localizedDescription)
    }
}
