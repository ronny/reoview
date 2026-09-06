# 0003. Build without Xcode

Status: accepted, 2026-09-06

## Context

The app needs a real `.app` bundle. `CFBundleIdentifier` gates keychain item
access, `UNUserNotificationCenter`, the `UserDefaults` domain, and window
restoration. A bundle is not the same thing as an Xcode project.

`swift build` and `swift test` cover the inner loop. `codesign`, `notarytool`,
`stapler`, and `iconutil` are all standalone command line tools.

## Decision

Use a plain SwiftPM package and a build script in the repository. The script
assembles the bundle, signs it, notarizes it, and staples the ticket.

The package has three targets:

- `ReolinkNVR` — transport, client, commands, models. It must not import AppKit.
- `ReolinkVideo` — the `VideoPlayer` protocol and the VLCKit implementation.
- `reolink-viewer` — the executable. SwiftUI views, `AppState`, controllers.

`ReolinkNVR` and `ReolinkVideo` each get a test target.

The app icon is a hand-built `.icns` from `iconutil`. Asset catalogs need
`actool` and are not used.

## Consequences

- The compiler enforces the test seam. `ReolinkNVR` cannot reach for AppKit.
- SwiftUI previews are not available.
- The signing order is explicit and understood, which milestone 7 needs anyway.
- If the build script becomes a burden, `swift-bundler` is a drop-in second
  choice.

## Alternatives

- `swift-bundler`. It does bundle assembly and signing. It may fight the
  non-standard VLCKit framework embedding.
- An Xcode project. It gives previews and asset catalogs, and it collapses the
  three targets into one, which removes the compiler-enforced seam.
