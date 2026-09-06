# 0007. Unsandboxed Developer ID app with re-signed VLCKit plugins

Status: accepted, 2026-09-06

## Context

The app must run on this Mac now, and it must be publishable as a signed archive
on GitHub later. There is a paid Apple Developer account. The App Store is not a
target.

Notarization needs the hardened runtime. Under the hardened runtime, library
validation requires every loaded dynamic library to carry the same Team ID as the
app.

VLCKit loads about one hundred plugin dynamic libraries from inside its
framework. VideoLAN signs them with the VideoLAN team. They will not load in a
notarized app that is signed by another team.

## Decision

Ship an unsandboxed app, signed with Developer ID, with the hardened runtime, and
notarized.

The build script signs inside-out. It re-signs every nested dynamic library and
framework inside `VLCKit.framework` with our Developer ID, then signs the app.
Do not use `codesign --deep`.

The app does not get the
`com.apple.security.cs.disable-library-validation` entitlement.

Prove this in the milestone 1 spike, not in milestone 7.

## Consequences

- A signed bundle that will not launch is found on day one, not at the end.
- The re-sign step is a loop over the plugin directory in the build script.
- The App Sandbox is not available later without work on keychain access and
  file access.

## Alternatives

- The `disable-library-validation` entitlement. It notarizes, it works, and it
  permanently weakens the app.
- A sandboxed app with `network.client` and `downloads.read-write`. It is real
  work against VLCKit's plugin loading, for no benefit on a LAN app.
- An ad-hoc signed local build. It cannot be published.
