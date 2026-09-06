# ReoView

A small native macOS app that shows the cameras on a Reolink NVR.

It replaces the Reolink macOS app and a Home Assistant dashboard for live
viewing. It talks to the NVR directly, so no other service sits in the video
path.

## Why it exists

Browsers hold a `NoDisplaySleep` power assertion for any visible playing
`<video>`. A web page cannot turn this off, so a dashboard left open keeps the
display awake all night. ReoView holds no assertion. This is measured, not
assumed: see [docs/display-sleep.md](docs/display-sleep.md).

## What it does

- A grid of camera tiles, in three layouts: grid, stacked, and columns.
- A choice of stream per camera, or every stream at once.
- Camera controls on each tile: PTZ, presets, guard position, zoom, floodlight,
  auto track, siren, quick reply, speaker volume, and manual record. Each one
  appears only when the device reports it.
- Motion, person, vehicle, and doorbell visitor state in the status strip, with
  a macOS notification when a visitor arrives.
- Players stop when the display sleeps, and start again on wake.

## What it does not do

- **Recordings.** Use the Reolink app. See
  [docs/plan.md](docs/plan.md).
- **Two-way talk.** It needs the Baichuan protocol on port 9000, and it is not
  yet known whether an NVR carries it at all. See
  [docs/research/baichuan-talk.md](docs/research/baichuan-talk.md).
- **Privacy mode.** There is no HTTP command for it. It needs Baichuan.
- **Quick reply clips.** The app plays them but cannot make them. Record one in
  the Reolink mobile app first, or the list stays empty.
- **iOS.** The UI is SwiftUI, so a target is possible, but none exists.

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
  --apple-id you@example.com --team-id TEAMID    # once
scripts/build-app.sh --notarize --verify --archive
```

The version comes from `git describe --tags`, so tag the repository first or the
build reads 0.0.0.

## Keyboard

| Keys | Action |
|---|---|
| `Cmd 1` to `Cmd 3` | Show one tile |
| `Esc` | Back to the grid |
| `F` | Full screen |
| `Cmd Ctrl G` / `S` / `C` | Grid, stacked, or columns layout |
| `Cmd +` / `Cmd -` / `Cmd 0` | Larger text and icons, smaller, or back to 100% |

Right-click a tile to choose which stream it shows.

macOS gives no text size setting to apps that Apple did not write, so ReoView
carries its own. It is in the settings sheet as well as on the keys above.

The menu bar item shows and hides the window. Closing the window does not quit
the app.

## Known limits

- The countermeasure that keeps the display free depends on a private VLCKit
  method. If a VLCKit upgrade renames it, the app blocks display sleep again and
  does so quietly. `DisplaySleepTests` is what catches this. Re-run the
  measurement in [docs/display-sleep.md](docs/display-sleep.md) after any
  upgrade.
- The siren toggle is local to the app. Nothing in the API reports whether the
  siren is sounding, so it reads off after a restart.
- The telephoto lens of the TrackMix plays over FLV, not RTSP, and only on
  VLCKit 4.0. The NVR answers 404 for every RTSP form of it.
- VLCKit 4.0 is an alpha.

## Documentation

| File | What it holds |
|---|---|
| [CONTEXT.md](CONTEXT.md) | The domain model, the verified stream URLs, and the device facts |
| [docs/plan.md](docs/plan.md) | Milestones and what is left |
| [docs/adr](docs/adr) | The decisions that would be expensive to reverse |
| [docs/display-sleep.md](docs/display-sleep.md) | Measurements of the one behavior the app exists for |
| [docs/research](docs/research) | Protocol research, with sources |
