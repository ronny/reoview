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

## Amendment, 2026-09-06

The context above is wrong about the shape of VLCKit 3.7.3. The decision does
not change.

The vendored framework holds no plugin dynamic libraries. A search for `*.dylib`
and `*.so` under `Vendor/VLCKit.xcframework` returns nothing. The VideoLAN
CocoaPods build links every VLC plugin statically into one 79 MB binary. The
`_vlc_static_modules` symbol is present, and no `vlc_entry__3_0_0_*` export
exists.

The framework still needs a new signature. As shipped it is ad-hoc signed, with
`Identifier=org.videolan.vlckitframework` and no Team ID. A binary with no Team
ID fails library validation under the hardened runtime.

The re-sign loop stays in `scripts/build-app.sh`. It reports how many nested
binaries it found, and zero is the correct count today. A later VLCKit that
ships loadable plugins needs no change to the script.

One measured consequence: an ad-hoc signature plus `--options runtime` makes
dyld reject the framework with "mapping process and mapped file (non-platform)
have different Team IDs". Two independent ad-hoc signatures both have no Team
ID, so they do not match. The `--adhoc` mode of the build script therefore signs
without the hardened runtime. Release signing is not affected.

## Amendment on revoked certificates, 2026-09-06

`security find-identity -v -p codesigning` counts a revoked certificate among
the valid ones. It marks it in the text as `CSSMERR_TP_CERT_REVOKED` and still
reports "1 valid identities found".

Signing with such a certificate is worse than not signing. Gatekeeper scanned
the result, decided it was malware, and moved the app to the trash:

```
syspolicyd: GK evaluateScanResult: 2, PST: (team: TEAMID), (id: au.ronny.ReoView)
syspolicyd: Attempting to move malware to trash
```

`scripts/build-app.sh` now refuses any identity whose line carries
`CSSMERR_TP_CERT_REVOKED`.

Two more findings from the same session:

- An Apple Development certificate is not a substitute for a Developer ID
  Application certificate. Only the latter is meant for an app that runs outside
  Xcode.
- A `.cer` file on its own installs the public half. Without the matching
  private key, `security find-identity` reports no identity at all. Create the
  certificate from the machine that will sign, so the key is generated there.
