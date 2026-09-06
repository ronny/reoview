import Foundation
import UserNotifications

/// Posts a macOS notification when a doorbell reports a visitor.
///
/// Authorisation is asked for once. A refusal is not an error the app reports:
/// the status strip dots keep working either way.
@MainActor
final class VisitorNotifier: NSObject {
    private var isAuthorised = false
    private var hasAsked = false

    /// `UNUserNotificationCenter.current()` traps in a process that is not in
    /// an app bundle, which is how the executable runs under `swift run`.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func activate() {
        guard let center, !hasAsked else { return }
        hasAsked = true
        center.delegate = self
        Task { [weak self] in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                self?.isAuthorised = granted
                Log.events.info("notification authorisation granted: \(granted, privacy: .public)")
            } catch {
                Log.events.error("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func visitorArrived(cameraName: String) {
        guard isAuthorised, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = cameraName
        content.body = "Someone is at the door."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            guard let error else { return }
            Log.events.error("notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension VisitorNotifier: UNUserNotificationCenterDelegate {
    /// Without this the banner is dropped while ReoView is the front app, and
    /// the app is meant to sit on screen all day.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
