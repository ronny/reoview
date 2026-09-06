import ReolinkNVR
import SwiftUI

/// The controls of the selected camera.
///
/// Every control here is gated twice: on `Capabilities`, and on the `Get` that
/// reported its current value. A control the camera does not have is absent,
/// not greyed out.
struct ControlsPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let camera = state.selectedCamera,
           let controls = state.controls,
           let capabilities = state.capabilities {
            Panel(camera: camera, controls: controls, capabilities: capabilities)
        }
    }
}

private struct Panel: View {
    @Environment(AppState.self) private var state

    let camera: Camera
    let controls: ControlsStore
    let capabilities: Capabilities

    private var channel: Int { camera.channel }
    private var values: CameraControlState { controls.state(for: camera.id) }

    var body: some View {
        if hasAnyControl {
            VStack(spacing: 0) {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        cameraPicker
                        ptzGroup
                        presetsAndGuard
                        switches
                        doorbellGroup
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
                // A `ScrollView` takes every point it is offered, and the grid
                // above it would lose them. This holds it to its content.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.bar)
            .disabled(!state.isNVRReachable)
            .onDisappear { controls.stopMove() }
        }
    }

    // MARK: - Groups

    @ViewBuilder
    private var cameraPicker: some View {
        if state.cameras.count > 1 {
            Picker("Camera", selection: cameraSelection) {
                ForEach(state.cameras, id: \.id) { camera in
                    Text(camera.name).tag(camera.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            Divider().frame(height: 26)
        }
    }

    @ViewBuilder
    private var ptzGroup: some View {
        if capabilities.supportsPan(channel: channel) || capabilities.supportsTilt(channel: channel) {
            PtzPad(
                pan: capabilities.supportsPan(channel: channel),
                tilt: capabilities.supportsTilt(channel: channel),
                onPress: { controls.startMove($0, cameraID: camera.id) },
                onRelease: { controls.stopMove() }
            )
            Divider().frame(height: 26)
        }

        if capabilities.supportsZoom(channel: channel), let range = values.zoomRange {
            SliderControl(
                title: "Zoom",
                symbol: "magnifyingglass",
                value: Double(values.zoom),
                bounds: Double(range.min)...Double(max(range.max, range.min + 1)),
                onChange: { controls.setZoom(Int($0.rounded()), cameraID: camera.id) }
            )
            Divider().frame(height: 26)
        }
    }

    @ViewBuilder
    private var presetsAndGuard: some View {
        if capabilities.supportsPtzPresets(channel: channel), !values.presets.isEmpty {
            Menu {
                ForEach(values.presets, id: \.id) { preset in
                    Button(name(of: preset)) {
                        controls.goToPreset(id: preset.id, cameraID: camera.id)
                    }
                }
            } label: {
                Label("Presets", systemImage: "mappin.and.ellipse")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(values.busy.contains(.preset))
        }

        if capabilities.supportsPtzGuard(channel: channel), values.hasGuard {
            Button {
                controls.goToGuardPosition(cameraID: camera.id)
            } label: {
                Label("Guard", systemImage: "house")
            }
            .disabled(!values.guardHasStoredPosition || values.busy.contains(.guardGo))
            .help("Send the camera back to its guard position")

            Button("Set") {
                controls.setGuardPositionToCurrent(cameraID: camera.id)
            }
            .disabled(values.busy.contains(.guardSet))
            .help("Make the current position the guard position")
        }

        if showsPresetsOrGuard {
            Divider().frame(height: 26)
        }
    }

    @ViewBuilder
    private var switches: some View {
        if capabilities.supportsFloodlight(channel: channel), values.hasFloodlight {
            ControlToggle(
                title: "Floodlight",
                symbol: "lightbulb",
                isOn: values.floodlightOn,
                isBusy: values.busy.contains(.floodlight),
                tint: .yellow
            ) { controls.setFloodlight($0, cameraID: camera.id) }
        }

        if capabilities.supportsAutoTrack(channel: channel), values.hasAutoTrack {
            ControlToggle(
                title: "Auto Track",
                symbol: "scope",
                isOn: values.autoTrackOn,
                isBusy: values.busy.contains(.autoTrack)
            ) { controls.setAutoTrack($0, cameraID: camera.id) }
        }

        if capabilities.supportsSiren(channel: channel) {
            ControlToggle(
                title: "Siren",
                symbol: "speaker.wave.3",
                isOn: values.sirenOn,
                isBusy: values.busy.contains(.siren),
                tint: .red
            ) { controls.setSiren($0, cameraID: camera.id) }
        }

        if capabilities.supportsManualRecord(channel: channel), values.hasManualRecord {
            ControlToggle(
                title: "Record",
                symbol: "record.circle",
                isOn: values.recording,
                isBusy: values.busy.contains(.manualRecord),
                tint: .red
            ) { controls.setManualRecord($0, cameraID: camera.id) }
        }
    }

    @ViewBuilder
    private var doorbellGroup: some View {
        if capabilities.supportsQuickReplyPlayback(channel: channel), !values.quickReplies.isEmpty {
            Divider().frame(height: 26)

            Picker("Quick Reply", selection: quickReplySelection) {
                ForEach(values.quickReplies, id: \.id) { file in
                    Text(file.fileName).tag(file.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .fixedSize()

            Button {
                controls.playQuickReply(cameraID: camera.id)
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(values.busy.contains(.quickReply))
            .help("Play the selected reply on the camera")
            .accessibilityLabel("Play quick reply")
        }

        if capabilities.supportsSpeakerVolume(channel: channel), values.hasSpeakerVolume {
            Divider().frame(height: 26)

            SliderControl(
                title: "Volume",
                symbol: "speaker.wave.2",
                value: Double(values.speakerVolume),
                bounds: 0...100,
                onChange: { controls.setSpeakerVolume(Int($0.rounded()), cameraID: camera.id) }
            )
        }
    }

    // MARK: - Bindings and tests

    private var cameraSelection: Binding<String> {
        Binding(get: { camera.id }, set: { state.selectCamera(id: $0) })
    }

    private var quickReplySelection: Binding<Int> {
        Binding(
            get: { values.selectedQuickReplyID ?? values.quickReplies.first?.id ?? -1 },
            set: { controls.selectQuickReply(id: $0, cameraID: camera.id) }
        )
    }

    private func name(of preset: GetPtzPreset.Preset) -> String {
        let name = preset.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Preset \(preset.id)" : name
    }

    private var showsPresetsOrGuard: Bool {
        (capabilities.supportsPtzPresets(channel: channel) && !values.presets.isEmpty)
            || (capabilities.supportsPtzGuard(channel: channel) && values.hasGuard)
    }

    private var hasAnyControl: Bool {
        capabilities.supportsPan(channel: channel)
            || capabilities.supportsTilt(channel: channel)
            || (capabilities.supportsZoom(channel: channel) && values.zoomRange != nil)
            || showsPresetsOrGuard
            || (capabilities.supportsFloodlight(channel: channel) && values.hasFloodlight)
            || (capabilities.supportsAutoTrack(channel: channel) && values.hasAutoTrack)
            || capabilities.supportsSiren(channel: channel)
            || (capabilities.supportsManualRecord(channel: channel) && values.hasManualRecord)
            || (capabilities.supportsQuickReplyPlayback(channel: channel) && !values.quickReplies.isEmpty)
            || (capabilities.supportsSpeakerVolume(channel: channel) && values.hasSpeakerVolume)
    }
}

// MARK: - PTZ pad

private struct PtzPad: View {
    let pan: Bool
    let tilt: Bool
    var onPress: (PtzOperation) -> Void
    var onRelease: () -> Void

    private var diagonals: Bool { pan && tilt }

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                button(.leftUp, "arrow.up.left", "Up and left", shown: diagonals)
                button(.up, "arrow.up", "Up", shown: tilt)
                button(.rightUp, "arrow.up.right", "Up and right", shown: diagonals)
            }
            GridRow {
                button(.left, "arrow.left", "Left", shown: pan)
                Button(action: onRelease) {
                    Image(systemName: "stop.fill")
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Stop")
                .accessibilityLabel("Stop moving")
                button(.right, "arrow.right", "Right", shown: pan)
            }
            GridRow {
                button(.leftDown, "arrow.down.left", "Down and left", shown: diagonals)
                button(.down, "arrow.down", "Down", shown: tilt)
                button(.rightDown, "arrow.down.right", "Down and right", shown: diagonals)
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
            Color.clear.frame(width: 26, height: 20)
        }
    }
}

/// One direction of the pad.
///
/// A `Button` fires on mouse-up and a long-press gesture waits out its delay,
/// so neither can start the movement on the way down. A zero-distance drag
/// gesture reports both halves of the press. Its `onEnded` runs on mouse-up
/// wherever the pointer has wandered to, and `onDisappear` covers the panel
/// going away mid-press; `ControlsStore` watches for the releases that reach
/// neither.
private struct PtzButton: View {
    let symbol: String
    let label: String
    var onPress: () -> Void
    var onRelease: () -> Void

    @State private var isPressed = false

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 26, height: 20)
            .background(
                isPressed ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12),
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

// MARK: - Pieces

private struct ControlToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let isBusy: Bool
    var tint: Color = .accentColor
    var action: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { action($0) })) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.button)
        .tint(tint)
        .disabled(isBusy)
        .fixedSize()
    }
}

private struct SliderControl: View {
    let title: String
    let symbol: String
    let value: Double
    let bounds: ClosedRange<Double>
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value.clamped(to: bounds) }, set: { onChange($0) }), in: bounds)
                .frame(width: 110)
                .accessibilityLabel(title)
        }
        .help(title)
    }
}

private extension Double {
    func clamped(to bounds: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, bounds.lowerBound), bounds.upperBound)
    }
}
