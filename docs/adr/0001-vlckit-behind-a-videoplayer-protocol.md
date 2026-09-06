# 0001. VLCKit behind a VideoPlayer protocol

Status: accepted, 2026-09-06

## Context

The app exists because:
1. the official Reolink macOS app is Intel only (as of Sep 2026 🙄), a resource hog, and has awful UX
2. even though cameras can be accessed via Home Assistant dashboard via a browser, BUT browsers
   hold a `NoDisplaySleep` power assertion for any visible playing `<video>`, preventing display
   sleep.

A lightweight native player can opt out of that assertion as well as provide additional features,
customised to how the user likes it.

libvlc has a core option `--no-disable-screensaver`. The option is present in the
VLC build on this machine. Screensaver inhibition is on by default, so the option
must be passed to `VLCLibrary(options:)`.

VLCKit is not yet proven to hold no assertion. If it does hold one, the fallback
is ffmpeg, VideoToolbox, and `AVSampleBufferDisplayLayer`. That fallback is a
much larger project, and it is in appetite.

## Decision

Use VLCKit for video. Put it behind a `VideoPlayer` protocol of about six
members: attach a view, play, stop, set muted, a state stream, and snapshot.

`PlayerController` owns a `VideoPlayer`. Every engine-independent behavior stays
in `PlayerController`: the reconnect backoff, the mute state, and the walk
through candidate stream URLs.

Milestone 1 is a spike and a gate. It must show that `pmset -g assertions` lists
no display assertion for the app process.

## Consequences

- A move to VideoToolbox replaces one type. No view code changes.
- Every player call gains one indirection.
- If the spike fails, we re-plan before we write more code.

## Alternatives

- VLCKit types used directly in the views. A fallback then touches every view.
- A larger abstraction that also covers the view layer and decoder
  configuration. That is design work for a fallback we may never build.

## Amendment, 2026-09-06

The decision holds and the gate is met. Two facts in the context above are now
wrong, and the reason the gate passes has changed completely.

`--no-disable-screensaver` is a VLC 3.x spelling. libvlc 4.0 made
`disable-screensaver` an integer, so the `--no-` form is rejected, and a
rejected option stops libvlc initialising at all. The accepted form is
`--disable-screensaver=0`.

More importantly, the option was never what made the gate pass. VLCKit 3.7.3
compiled in no inhibit module and imported no `IOPMAssertion` symbol, so it
could not hold an assertion whatever the option said. VLCKit 4.0 holds one from
its own Objective-C layer, which no libvlc option reaches. See
[display-sleep.md](../display-sleep.md) and
[ADR 0010](0010-neutralise-vlckit-display-sleep-assertion.md).

The `VideoPlayer` protocol earned its place. The move from VLCKit 3.7.3 to 4.0
changed one type and no view code.
