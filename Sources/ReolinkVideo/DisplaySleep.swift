import Foundation
import ObjectiveC.runtime
import os

/// Stops VLCKit holding a display sleep assertion.
///
/// VLCKit 4.0 added this to `VLCMediaPlayer` in its Objective-C layer:
///
/// ```objc
/// - (void)mediaPlayerStateChanged:(const VLCMediaPlayerState)newState {
///     if (newState == VLCMediaPlayerStatePlaying) {
///         [self preventDisplaySleep];
///     } else {
///         [self allowDisplaySleep];
///     }
/// }
/// ```
///
/// `preventDisplaySleep` calls `IOPMAssertionCreateWithName` with
/// `kIOPMAssertionTypeNoDisplaySleep`, named "VLC Media Playback". It is
/// unconditional, macOS only, and no header exposes a way to turn it off. No
/// libvlc option reaches it, including `disable-screensaver`, which only
/// controls libvlc's own `iokit_inhibit` module.
///
/// The app exists to let the display sleep while video is on screen, so the
/// method is replaced with one that does nothing. `allowDisplaySleep` is left
/// alone: it returns early when no assertion is held.
///
/// VLCKit 3.7.3 carries no such code, so this is a no-op there.
@MainActor
enum DisplaySleep {
    private static let log = Logger(subsystem: "au.ronny.ReoView", category: "displaysleep")

    /// True when the assertion has been neutralised, or when the VLCKit in use
    /// never held one. False means the app is blocking display sleep.
    private(set) static var isNeutralised = false

    static func stopVLCKitHoldingAssertions() {
        guard let playerClass = NSClassFromString("VLCMediaPlayer") else {
            log.error("VLCMediaPlayer class not found; cannot check the sleep assertion")
            return
        }

        let selector = NSSelectorFromString("preventDisplaySleep")
        guard let method = class_getInstanceMethod(playerClass, selector) else {
            // VLCKit 3.x, or a build that dropped the method. Nothing holds an
            // assertion, so there is nothing to undo.
            isNeutralised = true
            return
        }

        let noop: @convention(block) (AnyObject) -> Void = { _ in }
        method_setImplementation(method, imp_implementationWithBlock(noop))
        isNeutralised = true
        log.notice("neutralised VLCMediaPlayer.preventDisplaySleep")
    }
}
