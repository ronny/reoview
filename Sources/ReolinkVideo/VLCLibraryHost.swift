import Foundation
import VLCKit

/// Owns the one `VLCLibrary` the app uses.
///
/// The library exists to carry `--no-disable-screensaver`. libvlc inhibits the
/// screensaver by default whenever a video output is active, which is the
/// behaviour this app exists to avoid. See ADR 0001.
///
/// `VLCLibrary.sharedLibrary()` takes no options, so every player must be built
/// against this instance instead.
@MainActor
public enum VLCLibraryHost {
    /// Options passed to `VLCLibrary(options:)`. Library options take the
    /// command-line `--` form; per-media options take the `:` form.
    public nonisolated static let options: [String] = [
        "--no-disable-screensaver",
        "--rtsp-tcp",
        "--no-video-title-show",
        "--no-snapshot-preview",
        "--verbose=0",
    ]

    public static let shared: VLCLibrary = {
        let library = VLCLibrary(options: options)
        library.setHumanReadableName(
            "Reolink Viewer",
            withHTTPUserAgent: "ReolinkViewer/1.0"
        )
        return library
    }()

    /// Kept alive for the life of the process. `VLCDialogProvider` holds its
    /// renderer weakly, so both ends have to be retained here or libvlc's TLS
    /// question goes unanswered and the stream stalls.
    private static let certificateTrust: CertificateTrust = {
        let trust = CertificateTrust()
        if let provider = VLCDialogProvider(library: shared, customUI: true) {
            trust.attach(to: provider)
            dialogProvider = provider
        }
        return trust
    }()

    private static var dialogProvider: VLCDialogProvider?

    /// Accept the TLS certificate of `host` when libvlc asks about it.
    ///
    /// Called for every HTTPS URL the app plays. The app only ever plays URLs
    /// it built for the configured NVR, so the trusted set stays that narrow.
    static func trustCertificate(of host: String) {
        certificateTrust.trust(host: host)
    }
}
