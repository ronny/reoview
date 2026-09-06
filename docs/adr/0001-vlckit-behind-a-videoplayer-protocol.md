# 0001. VLCKit behind a VideoPlayer protocol

Status: accepted, 2026-09-06

## Context

The app exists because browsers hold a `NoDisplaySleep` power assertion for any
visible playing `<video>`. A native player can opt out of that assertion.

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
