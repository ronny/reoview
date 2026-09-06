import AppKit
import ReolinkVideo
import SwiftUI

@main
struct ReoViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ReoView", id: AppDelegate.mainWindowID) {
            RootView()
                .environment(delegate.state)
                .frame(minWidth: 720, minHeight: 440)
        }
        .commands {
            ViewCommands(state: delegate.state)
        }
    }
}

/// Puts the scale into the environment once, so no view has to reach into
/// `AppState` for it.
private struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ContentView()
            .environment(\.uiScale, UIScale(state.uiScale))
    }
}

private struct ViewCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandMenu("View") {
            // Cmd+Ctrl, because Cmd+1 to Cmd+3 already focus a tile and a bare
            // `F` toggles full screen.
            Toggle("Grid Layout", isOn: layout(.grid))
                .keyboardShortcut("g", modifiers: [.command, .control])
            Toggle("Stacked Layout", isOn: layout(.stacked))
                .keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Columns Layout", isOn: layout(.columns))
                .keyboardShortcut("c", modifiers: [.command, .control])
            Divider()
            Button("Tile 1") { state.focus(tileIndex: 0) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Tile 2") { state.focus(tileIndex: 1) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Tile 3") { state.focus(tileIndex: 2) }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Show All Tiles") { state.unfocus() }
            Divider()
            // The conventional zoom keys. Cmd+0 is free: the tile keys start
            // at Cmd+1.
            Button("Larger Text") { state.stepUIScale(by: 0.1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(state.uiScale >= AppConfig.uiScaleRange.upperBound)
            Button("Smaller Text") { state.stepUIScale(by: -0.1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(state.uiScale <= AppConfig.uiScaleRange.lowerBound)
            Button("Actual Text Size") { state.resetUIScale() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(state.uiScale == 1)
        }
    }

    private func layout(_ mode: LayoutMode) -> Binding<Bool> {
        Binding(get: { state.layout == mode }, set: { _ in state.layout = mode })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let state = AppState(makePlayer: { VLCVideoPlayer() })

    private var statusItem: NSStatusItem?
    private var fullScreenMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installFullScreenKey()
        restoreWindowFrame()
        state.startPresenceMonitoring()
        state.notifier.activate()
        Task { await state.connect() }
    }

    /// The menu bar item keeps the app alive with no window on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The NVR caps concurrent sessions, so the token must be given back before
    /// the process goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await state.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "ReoView")
        item.button?.target = self
        item.button?.action = #selector(toggleMainWindow)
        statusItem = item
    }

    @objc private func toggleMainWindow() {
        guard let window = mainWindow else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if window.isVisible && !window.isMiniaturized {
            window.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Keys

    /// `F` with no modifier. A menu key equivalent would swallow the letter
    /// while the settings sheet has a text field open.
    private func installFullScreenKey() {
        fullScreenMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased()
            let handled = MainActor.assumeIsolated {
                AppDelegate.toggleFullScreen(modifiers: modifiers, characters: characters)
            }
            return handled ? nil : event
        }
    }

    private static func toggleFullScreen(modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard modifiers.isEmpty,
              characters == "f",
              let window = NSApp.keyWindow,
              !(window.firstResponder is NSText)
        else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    // MARK: - Window frame

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true }
            ?? NSApp.windows.first { $0.styleMask.contains(.titled) && $0.canBecomeMain }
    }

    private func restoreWindowFrame() {
        guard let window = mainWindow else { return }

        if let saved = state.config.config.windowFrame {
            let frame = NSRectFromString(saved)
            if frame.width >= 720, frame.height >= 440 {
                window.setFrame(frame, display: true)
            }
        }

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveWindowFrame() }
            }
            windowObservers.append(token)
        }
    }

    private func saveWindowFrame() {
        guard let window = mainWindow, !window.styleMask.contains(.fullScreen) else { return }
        state.config.config.windowFrame = NSStringFromRect(window.frame)
    }
}
