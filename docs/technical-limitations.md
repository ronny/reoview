# Known technical limits

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
