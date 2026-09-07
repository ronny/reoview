import AppKit
import ReolinkNVR
import SwiftUI

/// The controls of one camera, over that camera's own tile.
///
/// Every control is gated twice: on `Capabilities`, and on the `Get` that
/// reported its current value. A control the camera does not have is absent,
/// not greyed out.
///
/// The row starts collapsed to one icon per group. An icon that needs more than
/// a single hit target opens a small panel above the row; a switch is its own
/// control, so its icon acts directly.
struct TileControls: View {
    @Environment(AppState.self) private var state

    let camera: Camera

    var body: some View {
        if let controls = state.controls, let capabilities = state.capabilities {
            ControlsOverlay(
                camera: camera,
                controls: controls,
                capabilities: capabilities,
                talk: state.talk
            )
            .disabled(!state.isNVRReachable)
        }
    }
}

/// One group of controls. Only the groups that need more than one hit target
/// are here; the switches act from their own icon.
private enum ControlGroup: Hashable {
    case ptz
    case zoom
    case presets
    case guardPosition
    case quickReply
    case volume
    case talk
}

private struct ControlsOverlay: View {
    @Environment(\.uiScale) private var ui

    let camera: Camera
    let controls: ControlsStore
    let capabilities: Capabilities
    let talk: TalkController

    @State private var open: ControlGroup?
    @State private var isHovering = false
    @State private var escapeMonitor: Any?

    private var channel: Int { camera.channel }
    private var values: CameraControlState { controls.state(for: camera.id) }

    var body: some View {
        if hasAnyControl {
            ZStack(alignment: .bottomLeading) {
                if open != nil {
                    // A click anywhere else on the tile puts the panel away.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { close() }
                }

                VStack(alignment: .leading, spacing: ui.length(6)) {
                    if let open {
                        panel(for: open)
                    }
                    iconRow
                }
                .padding(ui.length(8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // The siren sits apart from the rest, on the other side of the
            // tile. It is the only control here that makes a noise outside the
            // house, so it should not be a neighbour of anything you reach for
            // often.
            .overlay(alignment: .bottomTrailing) {
                if hasSiren {
                    IconButton(
                        // A beacon, not a speaker: the speaker symbols read as volume.
                        symbol: values.sirenOn ? "light.beacon.max.fill" : "light.beacon.max",
                        help: values.sirenOn ? "Stop the siren" : "Sound the siren on the camera",
                        isOn: values.sirenOn,
                        tint: .red,
                        isBusy: values.busy.contains(.siren)
                    ) { controls.setSiren(!values.sirenOn, cameraID: camera.id) }
                        .padding(ui.length(3))
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(ui.length(8))
                }
            }
            .opacity(isHovering || open != nil ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
            .onChange(of: open) { _, new in
                if new == nil { removeEscapeMonitor() } else { installEscapeMonitor() }
            }
            // The tile can go away mid-press: a layout change, a focus change,
            // or the panel itself collapsing. `PtzButton.onDisappear` covers the
            // pad, and this covers the whole overlay.
            // A talk session left open holds the camera's audio path, the
            // same way a held PTZ button leaves the camera turning.
            .onDisappear {
                removeEscapeMonitor()
                controls.stopMove()
                talk.stop()
            }
        }
    }

    // MARK: - The collapsed row

    /// `FlowLayout`, not `HStack`: a narrow tile must wrap the row onto a
    /// second line rather than push icons past its edge.
    private var iconRow: some View {
        FlowLayout(spacing: ui.length(3)) {
            if hasPtz {
                groupIcon(.ptz, "arrow.up.and.down.and.arrow.left.and.right", "Pan and tilt the camera")
            }
            if hasZoom {
                groupIcon(.zoom, "magnifyingglass", "Zoom the lens")
            }
            if hasPresets {
                groupIcon(.presets, "mappin.and.ellipse", "Move the camera to a saved preset")
            }
            if hasGuard {
                groupIcon(.guardPosition, "house", "Go to, or save, the guard position")
            }
            if hasFloodlight {
                IconButton(
                    symbol: values.floodlightOn ? "lightbulb.fill" : "lightbulb",
                    help: values.floodlightOn ? "Turn the floodlight off" : "Turn the floodlight on",
                    isOn: values.floodlightOn,
                    tint: .yellow,
                    isBusy: values.busy.contains(.floodlight)
                ) { controls.setFloodlight(!values.floodlightOn, cameraID: camera.id) }
            }
            if hasAutoTrack {
                IconButton(
                    symbol: "scope",
                    help: values.autoTrackOn
                        ? "Turn auto track off"
                        : "Turn auto track on, so the camera follows what it detects",
                    isOn: values.autoTrackOn,
                    isBusy: values.busy.contains(.autoTrack)
                ) { controls.setAutoTrack(!values.autoTrackOn, cameraID: camera.id) }
            }
            if hasTalk {
                groupIcon(.talk, "mic", "Talk to the camera, or say one of the saved phrases")
            }
            if hasQuickReply {
                groupIcon(.quickReply, "text.bubble", "Play a recorded reply on the camera speaker")
            }
            if hasVolume {
                groupIcon(.volume, "speaker.wave.2", "Set the volume of the camera speaker")
            }
            if hasManualRecord {
                IconButton(
                    symbol: values.recording ? "record.circle.fill" : "record.circle",
                    help: values.recording
                        ? "Stop recording to the NVR"
                        : "Start recording this camera to the NVR",
                    isOn: values.recording,
                    tint: .red,
                    isBusy: values.busy.contains(.manualRecord)
                ) { controls.setManualRecord(!values.recording, cameraID: camera.id) }
            }
        }
        .padding(ui.length(3))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
    }

    private func groupIcon(_ group: ControlGroup, _ symbol: String, _ help: String) -> some View {
        IconButton(symbol: symbol, help: help, isSelected: open == group) {
            toggle(group)
        }
    }

    // MARK: - The open panel

    @ViewBuilder
    private func panel(for group: ControlGroup) -> some View {
        Group {
            switch group {
            case .ptz:
                PtzPad(
                    pan: capabilities.supportsPan(channel: channel),
                    tilt: capabilities.supportsTilt(channel: channel),
                    onPress: { controls.startMove($0, cameraID: camera.id) },
                    onRelease: { controls.stopMove() }
                )
            case .zoom:
                zoomPanel
            case .presets:
                presetsPanel
            case .guardPosition:
                guardPanel
            case .quickReply:
                quickReplyPanel
            case .volume:
                volumePanel
            case .talk:
                TalkPanel(camera: camera, talk: talk)
            }
        }
        .font(ui.font(13))
        .padding(ui.length(8))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var zoomPanel: some View {
        if let range = values.zoomRange {
            let bounds = Double(range.min)...Double(max(range.max, range.min + 1))
            HStack(spacing: ui.length(6)) {
                Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { Double(values.zoom).clamped(to: bounds) },
                        set: { controls.setZoom(Int($0.rounded()), cameraID: camera.id) }
                    ),
                    in: bounds
                )
                .frame(width: ui.length(130))
                .accessibilityLabel("Zoom")
                Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
            }
            .help("Set how far the lens is zoomed in")
        }
    }

    private var presetsPanel: some View {
        FlowLayout(spacing: ui.length(4)) {
            ForEach(values.presets, id: \.id) { preset in
                Button(name(of: preset)) {
                    controls.goToPreset(id: preset.id, cameraID: camera.id)
                }
                .controlSize(.small)
                .disabled(values.busy.contains(.preset))
                .help("Move the camera to \(name(of: preset))")
            }
        }
        .frame(maxWidth: ui.length(320))
    }

    private var guardPanel: some View {
        HStack(spacing: ui.length(6)) {
            Button("Guard") {
                controls.goToGuardPosition(cameraID: camera.id)
            }
            .disabled(!values.guardHasStoredPosition || values.busy.contains(.guardGo))
            .help("Move to the guard position")

            Button("Set") {
                controls.setGuardPositionToCurrent(cameraID: camera.id)
            }
            .disabled(values.busy.contains(.guardSet))
            .help("Save the current position as the guard position")
        }
        .controlSize(.small)
    }

    private var quickReplyPanel: some View {
        HStack(spacing: ui.length(6)) {
            Menu {
                ForEach(values.quickReplies, id: \.id) { file in
                    Button(file.fileName) {
                        controls.selectQuickReply(id: file.id, cameraID: camera.id)
                    }
                }
            } label: {
                Text(selectedQuickReplyName)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: ui.length(150))
            .help("Choose which recorded reply to play")

            Button {
                controls.playQuickReply(cameraID: camera.id)
            } label: {
                Image(systemName: "play.fill")
            }
            .controlSize(.small)
            .disabled(values.busy.contains(.quickReply))
            .help("Play the chosen reply on the camera speaker")
            .accessibilityLabel("Play quick reply")
        }
    }

    private var volumePanel: some View {
        HStack(spacing: ui.length(6)) {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(values.speakerVolume).clamped(to: 0...100) },
                    set: { controls.setSpeakerVolume(Int($0.rounded()), cameraID: camera.id) }
                ),
                in: 0...100
            )
            .frame(width: ui.length(130))
            .accessibilityLabel("Speaker volume")
            Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
        }
        .help("Set the volume of the camera speaker")
    }

    // MARK: - Opening and closing

    /// A held PTZ button that is taken off screen must still release the
    /// camera. `PtzButton.onDisappear` does that, but SwiftUI can defer a
    /// removal, and a camera left turning is the worst failure this app has, so
    /// the stop goes out before the pad can leave.
    private func toggle(_ group: ControlGroup) {
        controls.stopMove()
        talk.stop()
        open = open == group ? nil : group
    }

    private func close() {
        controls.stopMove()
        talk.stop()
        open = nil
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is Escape. A text field owns its own Escape, so the settings
            // sheet keeps working while a panel is open behind it.
            guard event.keyCode == 53,
                  !(NSApp.keyWindow?.firstResponder is NSText)
            else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - What this camera has

    private var hasPtz: Bool {
        capabilities.supportsPan(channel: channel) || capabilities.supportsTilt(channel: channel)
    }

    private var hasZoom: Bool {
        capabilities.supportsZoom(channel: channel) && values.zoomRange != nil
    }

    private var hasPresets: Bool {
        capabilities.supportsPtzPresets(channel: channel) && !values.presets.isEmpty
    }

    private var hasGuard: Bool {
        capabilities.supportsPtzGuard(channel: channel) && values.hasGuard
    }

    private var hasFloodlight: Bool {
        capabilities.supportsFloodlight(channel: channel) && values.hasFloodlight
    }

    private var hasAutoTrack: Bool {
        capabilities.supportsAutoTrack(channel: channel) && values.hasAutoTrack
    }

    private var hasSiren: Bool {
        capabilities.supportsSiren(channel: channel)
    }

    private var hasQuickReply: Bool {
        capabilities.supportsQuickReplyPlayback(channel: channel) && !values.quickReplies.isEmpty
    }

    private var hasTalk: Bool { talk.isAvailable(for: camera) }

    private var hasVolume: Bool {
        capabilities.supportsSpeakerVolume(channel: channel) && values.hasSpeakerVolume
    }

    private var hasManualRecord: Bool {
        capabilities.supportsManualRecord(channel: channel) && values.hasManualRecord
    }

    private var hasAnyControl: Bool {
        hasPtz || hasZoom || hasPresets || hasGuard || hasFloodlight
            || hasAutoTrack || hasSiren || hasQuickReply || hasVolume || hasManualRecord
            || hasTalk
    }

    private var selectedQuickReplyName: String {
        let id = values.selectedQuickReplyID ?? values.quickReplies.first?.id
        return values.quickReplies.first { $0.id == id }?.fileName ?? "Reply"
    }

    private func name(of preset: GetPtzPreset.Preset) -> String {
        let name = preset.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Preset \(preset.id)" : name
    }
}

// MARK: - Icon button

private struct IconButton: View {
    @Environment(\.uiScale) private var ui

    let symbol: String
    let help: String
    var isOn = false
    var isSelected = false
    var tint: Color = .accentColor
    var isBusy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ui.font(12, weight: .semibold))
                .frame(width: ui.length(22), height: ui.length(20))
                // `.primary` rather than `Color.primary`: over a material it
                // takes the vibrancy that keeps it readable on a bright frame.
                .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .background(background, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        if isOn { return tint.opacity(0.9) }
        if isSelected { return .primary.opacity(0.18) }
        return .clear
    }
}

// MARK: - PTZ pad

private struct PtzPad: View {
    @Environment(\.uiScale) private var ui

    let pan: Bool
    let tilt: Bool
    var onPress: (PtzOperation) -> Void
    var onRelease: () -> Void

    private var diagonals: Bool { pan && tilt }

    var body: some View {
        Grid(horizontalSpacing: ui.length(2), verticalSpacing: ui.length(2)) {
            GridRow {
                button(.leftUp, "arrow.up.left", "Pan left and tilt up", shown: diagonals)
                button(.up, "arrow.up", "Tilt up", shown: tilt)
                button(.rightUp, "arrow.up.right", "Pan right and tilt up", shown: diagonals)
            }
            GridRow {
                button(.left, "arrow.left", "Pan left", shown: pan)
                Button(action: onRelease) {
                    Image(systemName: "stop.fill")
                        .frame(width: ui.length(22), height: ui.length(18))
                }
                .buttonStyle(.borderless)
                .help("Stop the camera moving")
                .accessibilityLabel("Stop moving")
                button(.right, "arrow.right", "Pan right", shown: pan)
            }
            GridRow {
                button(.leftDown, "arrow.down.left", "Pan left and tilt down", shown: diagonals)
                button(.down, "arrow.down", "Tilt down", shown: tilt)
                button(.rightDown, "arrow.down.right", "Pan right and tilt down", shown: diagonals)
            }
        }
    }

    @ViewBuilder
    private func button(
        _ direction: PtzOperation,
        _ symbol: String,
        _ label: String,
        shown: Bool
    ) -> some View {
        if shown {
            PtzButton(symbol: symbol, label: label) {
                onPress(direction)
            } onRelease: {
                onRelease()
            }
        } else {
            Color.clear.frame(width: ui.length(26), height: ui.length(20))
        }
    }
}

/// One direction of the pad.
///
/// A `Button` fires on mouse-up and a long-press gesture waits out its delay,
/// so neither can start the movement on the way down. A zero-distance drag
/// gesture reports both halves of the press. Its `onEnded` runs on mouse-up
/// wherever the pointer has wandered to, and `onDisappear` covers the pad going
/// away mid-press, which now also happens when the group is collapsed;
/// `ControlsStore` watches for the releases that reach neither.
private struct PtzButton: View {
    @Environment(\.uiScale) private var ui

    let symbol: String
    let label: String
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: symbol)
            .frame(width: ui.length(26), height: ui.length(20))
            .background(
                isPressed ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18),
                in: .rect(cornerRadius: 4)
            )
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press() }
                    .onEnded { _ in release() }
            )
            .onDisappear { release() }
            .help(label)
            .accessibilityLabel(label)
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        onPress()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

// MARK: - Flow layout

/// Lays its subviews out in rows, and starts a new row rather than let one run
/// past the width it was offered. A tile can be narrow, and a control that is
/// half off the edge cannot be clicked.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = rows(of: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for row in rows(of: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(of subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithThis = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width

            if !current.indices.isEmpty, widthWithThis > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = widthWithThis
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private extension Double {
    func clamped(to bounds: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, bounds.lowerBound), bounds.upperBound)
    }
}

// MARK: - Talk

/// Push to talk, and the saved phrases.
///
/// The button follows the same press-and-release discipline as the PTZ pad: a
/// zero-distance drag reports both halves, `onDisappear` covers the panel going
/// away mid-press, and `TalkController` watches for the releases that reach
/// neither.
private struct TalkPanel: View {
    @Environment(\.uiScale) private var ui

    let camera: Camera
    let talk: TalkController

    var body: some View {
        VStack(alignment: .leading, spacing: ui.length(6)) {
            HStack(spacing: ui.length(6)) {
                PushToTalkButton(
                    isHeld: talk.isPushToTalkHeld,
                    onPress: { talk.startPushToTalk(to: camera) },
                    onRelease: { talk.stopPushToTalk() }
                )

                Button {
                    talk.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .controlSize(.small)
                .disabled(!talk.isActive(cameraID: camera.id))
                .help("Stop talking and release the camera")
                .accessibilityLabel("Stop talking")
            }

            if !talk.phrases.isEmpty {
                Divider()
                FlowLayout(spacing: ui.length(4)) {
                    ForEach(Array(talk.phrases.enumerated()), id: \.offset) { _, phrase in
                        Button(shortened(phrase)) {
                            talk.speak(phrase, to: camera)
                        }
                        .controlSize(.small)
                        .disabled(talk.isPushToTalkHeld)
                        .help("Say \u{201C}\(phrase)\u{201D} through the camera speaker")
                    }
                }
                .frame(maxWidth: ui.length(320))
            }
        }
    }

    /// A phrase is a sentence; a button in a tile corner is not.
    private func shortened(_ phrase: String) -> String {
        phrase.count <= 28 ? phrase : String(phrase.prefix(27)) + "\u{2026}"
    }
}

private struct PushToTalkButton: View {
    @Environment(\.uiScale) private var ui

    let isHeld: Bool
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: ui.length(5)) {
            Image(systemName: isHeld ? "mic.fill" : "mic")
            Text("Hold to Talk")
        }
        .font(ui.font(12, weight: .semibold))
        .foregroundStyle(isHeld ? Color.white : .primary)
        .padding(.horizontal, ui.length(10))
        .frame(height: ui.length(24))
        .background(
            isHeld ? Color.red.opacity(0.9) : Color.secondary.opacity(0.18),
            in: .rect(cornerRadius: 5)
        )
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .onDisappear { release() }
        .help("Hold this button and speak. Release to stop.")
        .accessibilityLabel("Hold to talk")
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        onPress()
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

/// The unmistakable part: while the camera's speaker is open, the tile carries
/// a red badge with a stop control, outside the controls overlay that fades
/// when the pointer leaves.
struct TalkIndicator: View {
    @Environment(\.uiScale) private var ui

    let activity: TalkActivity
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: ui.length(6)) {
            Image(systemName: symbol)
                .symbolEffect(.pulse, options: .repeating)
            Text(activity.label)
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(ui.font(13))
            }
            .buttonStyle(.plain)
            .help("Stop talking and release the camera")
            .accessibilityLabel("Stop talking")
        }
        .font(ui.font(11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, ui.length(8))
        .padding(.vertical, ui.length(4))
        .background(Color.red.opacity(0.9), in: .capsule)
        .help(helpText)
    }

    private var symbol: String {
        switch activity {
        case .speaking: "speaker.wave.2.fill"
        default: "mic.fill"
        }
    }

    private var helpText: String {
        switch activity {
        case .connecting: "Opening the talk channel to the camera"
        case .listening: "Your microphone is going to the camera speaker"
        case .speaking(let phrase): "Saying \u{201C}\(phrase)\u{201D}"
        default: "Talking to the camera"
        }
    }
}
