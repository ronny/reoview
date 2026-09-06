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
    /// libvlc 4.0 dropped the `--no-` negation for this option and rejects
    /// `--no-disable-screensaver` outright, which stops the library from
    /// initialising at all. `--disable-screensaver=0` is the accepted form.
    ///
    /// This matters more on 4.0 than it did on 3.7.3. That build compiled in no
    /// inhibit module and could not take a power assertion whatever the option
    /// said. 4.0 ships `misc_inhibit_iokit` and calls
    /// `IOPMAssertionCreateWithName`, so the option now carries real weight.
    public nonisolated static let options: [String] = [
        "--disable-screensaver=0",
        "--rtsp-tcp",
        "--no-video-title-show",
        "--no-snapshot-preview",
        "--verbose=0",
    ]

    /// VLCKit reads an array named `VLCParams` from `NSUserDefaults` and uses it
    /// instead of the options passed to `VLCLibrary(options:)`. A stored array
    /// therefore silently discards every option below, including the one that
    /// stops libvlc holding a display assertion.
    ///
    /// The stored array is VLCKit's own, so it is kept and only the screensaver
    /// entry is replaced. Writing it back before the library is built is what
    /// makes the setting take effect.
    private static func enforceOptionsInUserDefaults() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: "VLCParams") ?? []
        let kept = stored.filter { !$0.hasPrefix("--disable-screensaver") }
        defaults.set(kept + options, forKey: "VLCParams")
    }

    public static let shared: VLCLibrary = {
        enforceOptionsInUserDefaults()
        let library = VLCLibrary(options: options)
        library.setHumanReadableName(
            "ReoView",
            withHTTPUserAgent: "ReoView/1.0"
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
