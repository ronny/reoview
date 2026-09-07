import Foundation
import UserNotifications

/// Posts a macOS notification when a doorbell reports a visitor.
///
/// Nothing here raises the system prompt on its own. `activate` only reads back
/// an answer macOS already has, and `requestAuthorization` is called from the
/// button in the onboarding wizard. A refusal is not an error the app reports:
/// the status strip dots keep working either way.
@MainActor
final class VisitorNotifier: NSObject {
    private var isAuthorised = false

    /// `UNUserNotificationCenter.current()` traps in a process that is not in
    /// an app bundle, which is how the executable runs under `swift run`.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// True when this process cannot post notifications at all, bundle or not.
    var isAvailable: Bool { center != nil }

    /// Takes the delegate and reads the standing answer. Silent: reading the
    /// settings never prompts.
    func activate() {
        guard let center else { return }
        center.delegate = self
        Task { [weak self] in
            let status = await center.notificationSettings().authorizationStatus
            self?.isAuthorised = status == .authorized || status == .provisional
        }
    }

    /// Asks macOS. This is the call that puts the prompt on screen, so it is
    /// only ever reached from a button the user pressed.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isAuthorised = granted
            Log.events.info("notification authorisation granted: \(granted, privacy: .public)")
            return granted
        } catch {
            Log.events.error("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What macOS says right now, without asking.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
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
