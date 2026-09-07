import Foundation
import Observation
import ReolinkNVR
import ReolinkVideo

/// The app-wide registry.
///
/// ADR 0004 and ADR 0006: this holds what the whole app shares — the camera
/// list, one `PlayerController` per tile, the client, and the reachability of
/// the NVR. Per-tile video state belongs to `PlayerController`, not here.
@MainActor
@Observable
final class AppState {
    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        case unreachable(String)
    }

    private(set) var cameras: [Camera] = []
    private(set) var capabilities: Capabilities?
    private(set) var controllers: [String: PlayerController] = [:]

    /// `StreamSource` ids, in grid order.
    private(set) var tileOrder: [String] = []

    private(set) var connection: Connection = .idle

    /// Set while one tile fills the window on its main stream.
    private(set) var focusedSourceID: String?

    private(set) var controls: ControlsStore?

    /// The last control command that the NVR refused. It shares the one global
    /// banner rather than adding a second place to look for a failure.
    private(set) var controlFailure: String?

    let config: ConfigStore
    let events = EventStatusStore()
    let notifier = VisitorNotifier()

    /// The one talk session in the app. It opens port 9000 on first use and
    /// gives it back when idle; see `TalkController`.
    let talk: TalkController

    @ObservationIgnored private let makePlayer: @MainActor () -> any VideoPlayer
    @ObservationIgnored private var client: NVRClient?
    @ObservationIgnored private var resolver: StreamResolver?
    @ObservationIgnored private var sourcesByID: [String: StreamSource] = [:]
    @ObservationIgnored private var sourcesByCameraID: [String: [StreamSource]] = [:]
    @ObservationIgnored private var camerasByID: [String: Camera] = [:]
    @ObservationIgnored private var codecBySourceID: [String: VideoCodec] = [:]
    @ObservationIgnored private var presence: PresenceMonitor?
    @ObservationIgnored private var poller: EventPoller?
    @ObservationIgnored private var shouldRunVideo = true
    @ObservationIgnored private var controlFailureTask: Task<Void, Never>?

    init(config: ConfigStore = ConfigStore(), makePlayer: @escaping @MainActor () -> any VideoPlayer) {
        self.config = config
        self.makePlayer = makePlayer
        self.talk = TalkController(config: config)
        // A refused talk reuses the one global banner, the same as a refused
        // control command.
        talk.onFailure = { [weak self] message in self?.noteControlFailure(message) }
        talk.onSuccess = { [weak self] in self?.clearControlFailure() }
    }

    // MARK: - Reachability

    var isNVRReachable: Bool { connection == .connected }

    /// One global banner for a dead NVR. A dead tile uses its own overlay, and
    /// a refused control borrows this one.
    var bannerMessage: String? {
        switch connection {
        case .unreachable(let message): message
        case .idle where config.config.host.isEmpty: "No NVR configured. Open Settings."
        default: controlFailure
        }
    }

    // MARK: - Lifecycle

    func startPresenceMonitoring() {
        let monitor = PresenceMonitor { [weak self] shouldRun in
            guard let self else { return }
            self.shouldRunVideo = shouldRun
            self.syncRunningPlayers()
            self.poller?.setVisible(shouldRun)
            // A hidden window or a sleeping display cannot be holding the
            // push-to-talk button, and the camera's audio path must not stay
            // open behind it.
            if !shouldRun { self.talk.stop() }
        }
        monitor.start()
        presence = monitor
    }

    func connect() async {
        let host = config.config.host
        let user = config.config.username
        guard !host.isEmpty, !user.isEmpty else {
            connection = .idle
            return
        }

        let password: String
        do {
            guard let stored = try KeychainStore.password(username: user, host: host) else {
                connection = .unreachable("No password is saved for \(user)@\(host)")
                return
            }
            password = stored
        } catch {
            connection = .unreachable("Could not read the password from the keychain")
            return
        }

        connection = .connecting
        let credentials = Credentials(user: user, password: password)
        let client = NVRClient(
            host: host,
            credentials: credentials,
            transport: URLSessionTransport(trustingSelfSignedCertificateFor: host)
        )
        self.client = client
        resolver = StreamResolver(host: host, credentials: credentials)

        do {
            try await client.login()
            try await discover(client: client, user: user)
            connection = .connected
            startEventPolling(client: client)
            await startControls(client: client)
        } catch {
            Log.app.error("connect to \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if Self.isLocalNetworkRefusal(error) {
                connection = .unreachable(Self.localNetworkMessage)
                scheduleConnectRetries()
            } else {
                connection = .unreachable(error.localizedDescription)
            }
        }
    }

    /// macOS 15 and later gate access to the local network per app, and the
    /// first request is refused while the prompt is on screen. `URLSession`
    /// reports that as `NSURLErrorNotConnectedToInternet`, so the app appears
    /// to say the internet is down when the NVR is one hop away.
    ///
    /// The grant arrives after the request has already failed, and nothing
    /// retries on its own, so a first run gets stuck on a stale error.
    static func isLocalNetworkRefusal(_ error: any Error) -> Bool {
        var candidates: [any Error] = [error]
        if case let .transport(underlying)? = error as? ReolinkError {
            candidates.append(underlying)
        }
        return candidates.contains { candidate in
            let ns = candidate as NSError
            return ns.domain == NSURLErrorDomain
                && (ns.code == NSURLErrorNotConnectedToInternet
                    || ns.code == NSURLErrorNetworkConnectionLost)
        }
    }

    static let localNetworkMessage =
        "Waiting for permission to reach devices on the local network. Allow it when macOS asks, and this connects on its own."

    /// Retries after a local network refusal, because the permission is granted
    /// out of band and nothing else would notice.
    private func scheduleConnectRetries() {
        connectRetry?.cancel()
        connectRetry = Task { [weak self] in
            for delay in [2, 3, 5, 8, 13, 20] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                guard case .unreachable = connection else { return }
                await connect()
                if case .connected = connection { return }
            }
        }
    }

    /// Retries now, for the button on the banner.
    func retryConnection() async {
        connectRetry?.cancel()
        await connect()
    }

    @ObservationIgnored private var connectRetry: Task<Void, Never>?

    func reconnect() async {
        await teardown()
        await connect()
    }

    /// The NVR caps concurrent sessions, so quit must give the token back.
    func shutdown() async {
        await teardown()
        presence?.stop()
        presence = nil
    }

    private func teardown() async {
        poller?.stop()
        poller = nil
        controls?.shutdown()
        controls = nil
        // Waits for the talk slot to be released before the process or the
        // connection goes away.
        await talk.shutdown()
        talk.setCapabilities(nil)
        clearControlFailure()
        events.clear()
        for controller in controllers.values {
            controller.stop()
        }
        if let client {
            do {
                try await client.logout()
            } catch {
                Log.app.error("logout failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        client = nil
    }

    // MARK: - Events

    /// ADR 0008: one poller for the whole app, started once the camera list is
    /// known.
    private func startEventPolling(client: NVRClient) {
        poller?.stop()
        let channels = cameras.map {
            EventPoller.Channel(cameraID: $0.id, name: $0.name, channel: $0.channel)
        }
        guard !channels.isEmpty else {
            poller = nil
            return
        }

        let poller = EventPoller(
            client: client,
            channels: channels,
            store: events,
            notifier: notifier,
            onProbe: { [weak self] present in
                self?.recordProbe(command: GetEvents.cmd, present: present)
            },
            onLastingFailure: { [weak self] message in
                self?.noteEventPollFailure(message)
            },
            onRecovery: { [weak self] in
                self?.noteEventPollRecovery()
            }
        )
        poller.setVisible(shouldRunVideo)
        poller.start()
        self.poller = poller
    }

    /// `GetAbility` reports nothing about `GetEvents`, so the poller's probe is
    /// the only source for it. Recording it here keeps every capability answer
    /// in one place, and `Capabilities.supportsGetEvents` then reads true.
    private func recordProbe(command: String, present: Bool) {
        capabilities = capabilities?.recording(command: command, present: present)
    }

    /// A poll that keeps failing means the NVR is gone, so it reuses the one
    /// global banner rather than adding a second signal.
    private func noteEventPollFailure(_ message: String) {
        guard connection == .connected else { return }
        connection = .unreachable(message)
    }

    private func noteEventPollRecovery() {
        guard case .unreachable = connection else { return }
        connection = .connected
    }

    // MARK: - Controls

    /// The controls read their own state once the camera list is known. The
    /// same pass probes the four commands that `GetAbility` says nothing about,
    /// so a control only appears after its command has answered.
    private func startControls(client: NVRClient) async {
        guard let capabilities, !cameras.isEmpty else {
            controls = nil
            return
        }
        let store = ControlsStore(
            client: client,
            cameras: cameras,
            capabilities: capabilities,
            onProbe: { [weak self] command, present in
                self?.recordProbe(command: command, present: present)
            },
            onFailure: { [weak self] message in
                self?.noteControlFailure(message)
            },
            onSuccess: { [weak self] in
                self?.clearControlFailure()
            }
        )
        controls = store
        await store.refresh()
    }

    /// A refused control writes to the one global banner, and takes itself back
    /// down so a single failure does not sit there for the rest of the session.
    private func noteControlFailure(_ message: String) {
        controlFailure = message
        controlFailureTask?.cancel()
        controlFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.controlFailure = nil
        }
    }

    private func clearControlFailure() {
        controlFailureTask?.cancel()
        controlFailureTask = nil
        controlFailure = nil
    }

    // MARK: - Cameras and tiles

    private func discover(client: NVRClient, user: String) async throws {
        let capabilities = try await client.send(GetAbility(userName: user)).capabilities
        let cameras = Camera.cameras(from: try await client.send(GetChannelstatus()))

        // One POST for every channel. ADR 0004: parallelism is batching.
        let encodings = try await client.send(cameras.map { (command: GetEnc(), channel: $0.channel) })

        self.capabilities = capabilities
        self.cameras = cameras
        talk.setCapabilities(capabilities)
        camerasByID = Dictionary(cameras.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        sourcesByID = [:]
        sourcesByCameraID = [:]
        codecBySourceID = [:]

        for (index, camera) in cameras.enumerated() {
            let sources = camera.streamSources(
                hasTelephotoLens: capabilities.hasTelephotoLens(channel: camera.channel)
            )
            sourcesByCameraID[camera.id] = sources
            let mainEncTypeVersion = capabilities.abilityVersion("mainEncType", channel: camera.channel)
            for source in sources {
                sourcesByID[source.id] = source
                codecBySourceID[source.id] = encodings[safe: index]?
                    .codec(source.quality, mainEncTypeVersion: mainEncTypeVersion) ?? .h264
            }
        }

        rebuildTiles(refreshingCandidates: true)
    }

    /// Rebuilds the tile list from the per-camera stream selections, then hands
    /// the running set back to `syncRunningPlayers`. Controllers for sources
    /// that are no longer shown are stopped before they go, so the NVR gets its
    /// RTSP session back.
    ///
    /// `refreshingCandidates` is for a fresh discovery, where the codec and the
    /// host may have changed. A selection change leaves the surviving tiles
    /// alone, because `setCandidates` restarts a playing stream.
    private func rebuildTiles(refreshingCandidates: Bool = false) {
        let ids = tileIDs()
        tileOrder = ids
        pruneFocus(tileIDs: ids)

        var wanted = Set(ids)
        if let focusedSourceID { wanted.insert(focusedSourceID) }

        for id in controllers.keys.filter({ !wanted.contains($0) }) {
            controllers[id]?.stop()
            controllers.removeValue(forKey: id)
        }

        for id in wanted {
            guard let source = sourcesByID[id] else { continue }
            let controller = controller(for: source)
            if refreshingCandidates {
                controller.setCandidates(candidates(for: source))
            }
        }

        enforceSingleUnmutedTile()
        syncRunningPlayers()
    }

    /// A focused tile survives a selection change to another camera. It does
    /// not survive its own camera losing every tile, or its source going away
    /// with the lens.
    private func pruneFocus(tileIDs ids: [String]) {
        guard let focused = focusedSourceID else { return }
        let survives = sourcesByID[focused].map { source in
            ids.contains { sourcesByID[$0]?.cameraID == source.cameraID }
        } ?? false
        if !survives { focusedSourceID = nil }
    }

    /// A saved config could name more than one unmuted tile.
    private func enforceSingleUnmutedTile() {
        var found = false
        for id in tileOrder {
            guard let controller = controllers[id], !controller.isMuted else { continue }
            if found {
                controller.setMuted(true)
                config.config.mutedBySourceID[id] = true
            } else {
                found = true
            }
        }
    }

    /// The `StreamSource` ids the grid shows, in camera order, from the
    /// per-camera selections.
    private func tileIDs() -> [String] {
        var ids: [String] = []
        for camera in cameras {
            let sources = sourcesByCameraID[camera.id] ?? []
            guard !sources.isEmpty else { continue }
            switch selection(for: camera.id) {
            case .all:
                ids.append(contentsOf: sources.map(\.id))
            case .source(let id) where sources.contains(where: { $0.id == id }):
                ids.append(id)
            case .standard, .source:
                ids.append(contentsOf: Self.standardIDs(of: sources))
            }
        }
        return ids
    }

    /// The grid per CONTEXT.md: the sub stream of every wide lens, then the
    /// main stream of a telephoto lens, which has no sub stream. On the
    /// verified NVR that is Front Door sub, Driveway wide sub, and Driveway
    /// telephoto main.
    private static func standardIDs(of sources: [StreamSource]) -> [String] {
        var ids: [String] = []
        for lens in Lens.allCases {
            let forLens = sources.filter { $0.lens == lens }
            guard let pick = forLens.first(where: { $0.quality == .sub }) ?? forLens.first else { continue }
            ids.append(pick.id)
        }
        return ids
    }

    // MARK: - Stream selection

    func sources(for cameraID: String) -> [StreamSource] {
        sourcesByCameraID[cameraID] ?? []
    }

    func selection(for cameraID: String) -> StreamSelection {
        config.config.streamSelectionByCameraID[cameraID] ?? .standard
    }

    func setSelection(_ selection: StreamSelection, cameraID: String) {
        guard selection != self.selection(for: cameraID) else { return }
        config.config.streamSelectionByCameraID[cameraID] = selection
        rebuildTiles()
    }

    func label(for source: StreamSource) -> String {
        "\(source.lens.rawValue.capitalized) \(source.quality.rawValue)"
    }

    // MARK: - Layout

    var layout: LayoutMode {
        get { config.config.layout }
        set { config.config.layout = newValue }
    }

    // MARK: - UI scale

    /// `AppConfig` clamps what it is given, so a step past either end settles
    /// on the end.
    var uiScale: Double {
        get { config.config.uiScale }
        set { config.config.uiScale = newValue }
    }

    func stepUIScale(by delta: Double) {
        uiScale = ((uiScale + delta) * 10).rounded() / 10
    }

    func resetUIScale() {
        uiScale = 1
    }

    @discardableResult
    private func controller(for source: StreamSource) -> PlayerController {
        if let existing = controllers[source.id] { return existing }
        let controller = PlayerController(
            source: source,
            title: title(for: source),
            player: makePlayer(),
            candidates: candidates(for: source),
            muted: config.config.mutedBySourceID[source.id] ?? true
        )
        controller.onWinningURL = { [weak self] source, url in
            self?.rememberWinner(source: source, url: url)
        }
        controllers[source.id] = controller
        return controller
    }

    func title(for source: StreamSource) -> String {
        guard let camera = camerasByID[source.cameraID] else { return source.id }
        let lenses = Set((sourcesByCameraID[camera.id] ?? []).map(\.lens))
        guard lenses.count > 1 else { return camera.name }
        return "\(camera.name) \(source.lens.rawValue)"
    }

    func camera(for source: StreamSource) -> Camera? {
        camerasByID[source.cameraID]
    }

    // MARK: - Candidate URLs

    /// The ordered candidate list from `StreamResolver`, with the URL that last
    /// played moved to the front.
    private func candidates(for source: StreamSource) -> [URL] {
        guard let resolver,
              let camera = camerasByID[source.cameraID]
        else { return [] }

        let ordered = resolver.candidates(
            for: source,
            channel: camera.channel,
            codec: codecBySourceID[source.id] ?? .h264
        )

        guard let winner = config.config.winningURLBySourceID[source.id],
              let index = ordered.firstIndex(where: { $0.withoutCredentials == winner })
        else { return ordered }

        var reordered = ordered
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    private func rememberWinner(source: StreamSource, url: URL) {
        config.config.winningURLBySourceID[source.id] = url.withoutCredentials
    }

    // MARK: - Mute

    /// Tiles start muted, and only one may be unmuted at a time.
    func setMuted(_ muted: Bool, sourceID: String) {
        guard let target = controllers[sourceID] else { return }
        if !muted {
            for (id, controller) in controllers where id != sourceID {
                controller.setMuted(true)
                config.config.mutedBySourceID[id] = true
            }
        }
        target.setMuted(muted)
        config.config.mutedBySourceID[sourceID] = muted
    }

    func toggleMuted(sourceID: String) {
        guard let controller = controllers[sourceID] else { return }
        setMuted(!controller.isMuted, sourceID: sourceID)
    }

    // MARK: - Single tile

    /// Double-click, or Cmd+1 to Cmd+3. The single view shows the main stream,
    /// so the tile switches to the main-quality source of the same lens.
    func focus(sourceID: String) {
        guard let source = sourcesByID[sourceID] else { return }
        let target = mainQualitySource(for: source)
        controller(for: target)
        // Focusing takes the grid off screen, which can remove a held PTZ
        // or push-to-talk button. Their `onDisappear` also releases; this does
        // not wait for SwiftUI to get round to it.
        controls?.stopMove()
        talk.stop()
        focusedSourceID = target.id
        syncRunningPlayers()
    }

    func focus(tileIndex: Int) {
        guard let id = tileOrder[safe: tileIndex], let source = sourcesByID[id] else { return }
        if focusedSourceID == mainQualitySource(for: source).id {
            unfocus()
        } else {
            focus(sourceID: id)
        }
    }

    func unfocus() {
        guard focusedSourceID != nil else { return }
        controls?.stopMove()
        talk.stop()
        focusedSourceID = nil
        syncRunningPlayers()
    }

    private func mainQualitySource(for source: StreamSource) -> StreamSource {
        let main = StreamSource(cameraID: source.cameraID, lens: source.lens, quality: .main)
        return sourcesByID[main.id] ?? source
    }

    /// The NVR rations concurrent RTSP sessions, so only the tiles on screen
    /// hold one.
    private func syncRunningPlayers() {
        let wanted: Set<String>
        if !shouldRunVideo {
            wanted = []
        } else if let focusedSourceID {
            wanted = [focusedSourceID]
        } else {
            wanted = Set(tileOrder)
        }

        for (id, controller) in controllers {
            if wanted.contains(id) {
                controller.start()
            } else {
                controller.stop()
            }
        }
    }

    // MARK: - Settings

    /// Saving new credentials always retries, whatever the banner says.
    func saveSettings(host: String, username: String, password: String) async {
        connectRetry?.cancel()
        let previous = (username: config.config.username, host: config.config.host)

        if !password.isEmpty {
            do {
                try KeychainStore.setPassword(password, username: username, host: host)
            } catch {
                connection = .unreachable("Could not save the password to the keychain")
                return
            }
        }

        if !previous.username.isEmpty, previous != (username, host) {
            try? KeychainStore.deletePassword(username: previous.username, host: previous.host)
        }

        config.config.host = host
        config.config.username = username
        await reconnect()
    }
}

extension URL {
    /// The same URL with the user and password removed, so it can be written to
    /// `UserDefaults` without leaking the NVR password. The FLV candidate
    /// carries them as query items rather than as user info.
    var withoutCredentials: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.filter {
            $0.name != "user" && $0.name != "password"
        }
        return components.string ?? absoluteString
    }
}
