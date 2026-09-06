import AppKit

/// The single owner of the question "should video be running right now?".
///
/// ADR 0009: the app exists so that the display can sleep with video on
/// screen. Players stop outright on display sleep and on window occlusion, and
/// open again through the normal reconnect path. Keeping both signals here
/// stops the rule from being duplicated in views and controllers.
@MainActor
final class PresenceMonitor {
    private let onChange: @MainActor (Bool) -> Void

    private var screensAsleep = false
    private var windowVisible = true
    private var lastReported = true
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    var shouldRunVideo: Bool { !screensAsleep && windowVisible }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            observe(center, name) { $0.refreshWindowVisibility() }
        }

        refreshWindowVisibility()
        report()
    }

    func stop() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observers.removeAll()
    }

    private func refreshWindowVisibility() {
        windowVisible = NSApp?.windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        } ?? false
    }

    private func report() {
        let value = shouldRunVideo
        guard value != lastReported else { return }
        lastReported = value
        Log.presence.info("video should run: \(value, privacy: .public)")
        onChange(value)
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (PresenceMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // The notification arrives on the main queue, but a window is not
            // finished closing until the next turn of the run loop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                handler(self)
                self.refreshWindowVisibility()
                self.report()
            }
        }
        observers.append(token)
    }
}
