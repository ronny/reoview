import AppKit
import Foundation

/// Catches the releases a press gesture never sees.
///
/// A mouse-up outside the button, or the app losing focus mid-press, never
/// reaches the gesture that started the press. AppKit delivers the mouse-up to
/// the window that took the mouse-down whatever is under the pointer, so the
/// monitor sees the releases the gesture misses.
///
/// Both users of this hold something the user cannot take back by themselves: a
/// camera left turning, or a talk session holding the camera's audio path. The
/// two ends are told apart because they do not always call for the same
/// release: a lost mouse-up ends a held button, while resigning active also
/// ends work nobody is holding.
@MainActor
final class LostReleaseWatcher {
    private let onMouseUp: @MainActor () -> Void
    private let onResignActive: @MainActor () -> Void

    private var mouseUpMonitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    init(
        onMouseUp: @escaping @MainActor () -> Void,
        onResignActive: @escaping @MainActor () -> Void
    ) {
        self.onMouseUp = onMouseUp
        self.onResignActive = onResignActive
    }

    /// Safe to call while already watching: a second press does not install a
    /// second monitor.
    func start() {
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [onMouseUp] event in
                MainActor.assumeIsolated { onMouseUp() }
                return event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [onResignActive] _ in
                MainActor.assumeIsolated { onResignActive() }
            }
        }
    }

    /// Safe to call when nothing is installed, and safe to call twice.
    func stop() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
