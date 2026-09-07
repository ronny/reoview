# ReoView

A small native macOS app that shows the cameras on a Reolink NVR.

## Not affiliated with Reolink

This app is NOT an official Reolink project.

Reolink is a trademark of its owner. ReoView is an independent client, developed
by reading a public API and by measuring one NVR. It is not endorsed by, and
carries no code from, Reolink.

## Why it exists

I wanted an app that shows live video feeds from my Reolink NVR that I can just
leave running all the time.

The official Reolink macOS app is not a universal mac app, it's Intel-only
(as of Sept 2026) so it will run emulated under Rosetta. It runs with very
high CPU usage almost all of the time. At one point it left 75 GB of SDK log
files on my system.

I _could_ use a Home Assistant dashboard, but playing video stream in browsers
cause the display to stay awake. Browsers hold a `NoDisplaySleep` power assertion
for any visible playing `<video>` (check with `pmset -g assertions`). A web page
cannot turn this off, so a dashboard left open keeps the display awake all night.

## Supported features

- A grid of camera tiles, in three layouts: grid, stacked, and columns.
- A choice of stream per camera, or every stream at once.
- Camera controls on each tile: PTZ, presets, guard position, zoom, floodlight,
  auto track, siren, quick reply, speaker volume, and manual record. Each one
  appears only when the device reports it.
- Motion, person, vehicle, and doorbell visitor state in the status strip, with
  a macOS notification when a visitor arrives.
- Two-way talk to the doorbell: hold to speak, or send one of a list of phrases
  that this Mac speaks and the camera plays.

## Runtime requirements

**macOS 14 or later.** Apple silicon or Intel.

**A Reolink NVR.** The app talks to an NVR and addresses cameras by channel. A
camera on its own network address is not supported: there is no way to configure
one, and the discovery, the capability gating and the stream URLs all assume an
NVR is answering. Cameras that sit behind the PoE ports of the NVR do not need
to be reachable themselves, and on most setups they are not.

**An account on the NVR.** Make a dedicated one rather than reusing another
client's. PTZ and settings need administrator rights.

**Permission to reach devices on the local network**, on macOS 15 and later.
Refuse it and every request fails as though the network were down.

A first run opens a setup wizard: the NVR address and account, then a button for
each permission macOS gates — the local network, notifications, and the
microphone. No prompt appears until its button is pressed, and the last two are
optional.

### Tested against

| | |
|---|---|
| NVR | Reolink RLN8-410, firmware v3.6.5.562 |
| Doorbell | Reolink Video Doorbell PoE, on channel 0 |
| Camera | Reolink TrackMix PoE, on channel 1 |
| Mac | macOS 26.6 |

That is the whole of it: one NVR, one firmware, two cameras. Everything in
[docs/initial-context.md](docs/initial-context.md) was measured against that
hardware and nothing else.

Other Reolink NVRs will probably work, because the app asks the device what it
supports rather than assuming, and hides a control the device does not report.
Two things are likelier than most to differ on other hardware:

- **The telephoto lens of a dual-lens camera.** On this NVR every RTSP form of
  it answers 404 and only FLV carries it, which in turn needs VLCKit 4.0. Other
  firmware may serve it over RTSP.
- **Two-way talk.** Reolink's own support article says two-way audio cannot be
  used when a camera is on an NVR. On this one it can, measured and working.
  That flatly contradicts the vendor, so treat it as a property of this model
  and firmware until someone tries another.

Battery cameras, Wi-Fi cameras that do not go through an NVR, and Reolink's
cloud have not been tried at all.

## Unsupported features

- **Recordings search and playback.** Use the official Reolink app for now.
- **Camera / NVR configuration.** Use the official Reolink app for now.
- **Privacy mode.** There is no HTTP command for it. It needs Baichuan, which
  the app now speaks, so this is reachable rather than blocked.

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

See [docs/technical-limitations.md](docs/technical-limitations.md).

## Building the app

See [docs/build.md](docs/build.md).

## Credits

ReoView is under the Apache License 2.0. See [LICENSE](LICENSE).

VLCKit ships inside the application under the LGPL 2.1, the app icon uses a
Material Symbols glyph under the Apache License 2.0, and the protocol work was
learned by reading several open projects. [CREDITS.md](CREDITS.md) lists each
one, its licence, and what a redistributor has to do about it.

Not affiliated with Reolink.

## AI use disclosure

All of the code in this repository was/is written by Claude Opus 5 under heavy
supervision and direction from me.
