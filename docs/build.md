# Building the app

## Requirements

- macOS 14 or later.
- The Xcode command line tools, for `swiftc`, `codesign`, and `xcodebuild`.
  There is no Xcode project. See
  [ADR 0003](docs/adr/0003-build-without-xcode.md).
- A Reolink NVR on the local network, and a user account on it. Make a dedicated
  admin user. PTZ and settings need admin.
- About 1 GB of disk for the VLCKit download and the extracted framework.
- A Developer ID Application certificate, but only to make a notarized build. A
  local build does not need one.

Developed against an RLN8-410 on firmware v3.6.5.562, with a Video Doorbell PoE
and a TrackMix PoE. Nothing else has been tried.

## Build and run

```bash
scripts/fetch-vlckit.sh          # about 900 MB, once
scripts/build-app.sh --adhoc     # writes dist/ReoView.app
open dist/ReoView.app
```

Then open the settings sheet from the gear in the status strip. Give it the NVR
address, the user name, and the password. The password goes to the keychain and
nowhere else.

The first connection asks for permission to reach devices on the local network.
Accept it, or every request fails as if the network were down.

To work on the code:

```bash
swift build
scripts/test.sh                  # not `swift test`, see below
```

`scripts/test.sh` links VLCKit into the test bundle before it runs. SwiftPM does
not do this itself, and `swift test` fails to load the bundle without it.

## Release

```bash
xcrun notarytool store-credentials reoview \
  --apple-id you@example.com --team-id TEAMID    # once, and the name matters:
                                                 # build-app.sh looks for reoview
scripts/build-app.sh --notarize --verify --archive
```

The version comes from `git describe --tags`, so tag the repository first or the
build reads 0.0.0.
