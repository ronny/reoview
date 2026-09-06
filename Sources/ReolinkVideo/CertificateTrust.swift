import Foundation
import VLCKit
import os

/// Answers libvlc's TLS questions for hosts this app has deliberately opened.
///
/// VLC carries its own TLS stack, so a `URLSession` trust delegate does not
/// reach it. The NVR serves its FLV streams over HTTPS with a self-signed
/// certificate, and libvlc rejects it: "certificate verification failed,
/// result is 5". RTSP is unaffected because it carries no TLS, so this only
/// shows up on the streams that have no RTSP form.
///
/// Trust is scoped to the hosts passed to `trust(host:)`, which is only ever
/// the host of a URL the app decided to play. Every other dialog is cancelled.
final class CertificateTrust: NSObject, VLCCustomDialogRendererProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var trustedHosts: Set<String> = []
    private weak var provider: VLCDialogProvider?
    private let log = Logger(subsystem: "au.ronny.ReolinkViewer", category: "tls")

    /// libvlc's cancel button is button 3.
    private static let cancelButton: Int32 = 3

    func attach(to provider: VLCDialogProvider) {
        self.provider = provider
        provider.customRenderer = self
    }

    func trust(host: String) {
        lock.lock()
        defer { lock.unlock() }
        trustedHosts.insert(host.lowercased())
    }

    private func isTrusted(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let haystack = text.lowercased()
        return trustedHosts.contains { haystack.contains($0) }
    }

    func showQuestion(
        withTitle title: String,
        message: String,
        type questionType: VLCDialogQuestionType,
        cancel cancelString: String?,
        action1String: String?,
        action2String: String?,
        withReference reference: NSValue
    ) {
        guard isTrusted(title + " " + message) else {
            log.notice("declining a TLS question for an untrusted host")
            provider?.postAction(Self.cancelButton, forDialogReference: reference)
            return
        }

        guard let button = Self.acceptButton(action1String, action2String) else {
            log.notice("no accepting action offered, cancelling")
            provider?.postAction(Self.cancelButton, forDialogReference: reference)
            return
        }
        provider?.postAction(button, forDialogReference: reference)
    }

    /// Picks the button that accepts for the longest, by reading the labels
    /// rather than assuming a fixed order.
    ///
    /// libvlc asks twice. The first dialog offers "View certificate", which
    /// would loop forever, so anything that only shows the certificate is
    /// rejected here. The second offers a temporary and a permanent accept.
    static func acceptButton(_ action1: String?, _ action2: String?) -> Int32? {
        let candidates: [(Int32, String)] = [(Int32(1), action1), (Int32(2), action2)]
            .compactMap { (pair: (Int32, String?)) -> (Int32, String)? in
                guard let label = pair.1, !label.isEmpty else { return nil }
                return (pair.0, label.lowercased())
            }
            .filter { _, label in
                !label.contains("view") && !label.contains("abort") && !label.contains("cancel")
            }

        if let permanent = candidates.first(where: { $0.1.contains("permanent") }) {
            return permanent.0
        }
        if let accept = candidates.first(where: { $0.1.contains("accept") }) {
            return accept.0
        }
        return candidates.last?.0
    }

    func showLogin(
        withTitle title: String,
        message: String,
        defaultUsername username: String?,
        askingForStorage: Bool,
        withReference reference: NSValue
    ) {
        // Credentials travel inside the stream URLs, so a login prompt means
        // something unexpected. Never answer one.
        provider?.postUsername("", andPassword: "", forDialogReference: reference, store: false)
    }

    func showError(withTitle error: String, message: String) {
        log.error("libvlc: \(error, privacy: .public)")
    }

    func showProgress(
        withTitle title: String,
        message: String,
        isIndeterminate: Bool,
        position: Float,
        cancel cancelString: String?,
        withReference reference: NSValue
    ) {}

    func updateProgress(withReference reference: NSValue, message: String?, position: Float) {}

    func cancelDialog(withReference reference: NSValue) {}
}
