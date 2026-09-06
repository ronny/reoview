import Foundation
import IOKit.pwr_mgt
import ObjectiveC.runtime
import Testing
import VLCKit
@testable import ReolinkVideo

@Suite("Display sleep")
@MainActor
struct DisplaySleepTests {
    /// The app exists so that video on screen does not block display sleep.
    /// VLCKit 4.0 holds an assertion from its Objective-C layer that no libvlc
    /// option reaches, so this guards the one countermeasure.
    @Test("Calling preventDisplaySleep creates no assertion")
    func preventIsANoop() throws {
        DisplaySleep.stopVLCKitHoldingAssertions()
        #expect(DisplaySleep.isNeutralised)

        let selector = NSSelectorFromString("preventDisplaySleep")
        let player = VLCMediaPlayer(library: VLCLibraryHost.shared)

        // VLCKit 3.x has no such method and holds no assertion either way.
        guard player.responds(to: selector) else { return }

        let before = Self.displayAssertionCount()
        player.perform(selector)
        #expect(Self.displayAssertionCount() == before)
    }

    /// This process's own no-display-sleep assertions.
    private static func displayAssertionCount() -> Int {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return 0 }

        return (byProcess[NSNumber(value: getpid())] ?? []).filter {
            ($0[kIOPMAssertionTypeKey as String] as? String)?.contains("NoDisplaySleep") == true
        }.count
    }
}
