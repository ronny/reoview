# ReoView

A small native macOS app that shows the cameras on a Reolink NVR.

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

The app icon uses the Material Symbols glyph `nest_cam_iq_outdoor`, from
[google/material-design-icons](https://github.com/google/material-design-icons),
under the Apache License 2.0. The blue is sampled from Reolink's own app icon so
the two sit together in the Dock. Nothing of Reolink's own branding is used.

Payload shapes for the HTTP API come from reading
[starkillerOG/reolink_aio](https://github.com/starkillerOG/reolink_aio). The
Baichuan protocol notes draw on that and on
[QuantumEntangledAndy/neolink](https://github.com/QuantumEntangledAndy/neolink);
sources are cited per claim in [docs/research](docs/research).

## AI use disclosure

All of the code in this repository was/is written by Claude Opus 5 under heavy
supervision and direction from me.
