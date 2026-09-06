# 0010. Neutralize the display sleep assertion in VLCKit

Status: accepted, 2026-09-06

## Context

The app exists so that video on screen does not block display sleep. See
[ADR 0001](0001-vlckit-behind-a-videoplayer-protocol.md).

VLCKit 4.0 holds a display sleep assertion of its own. `VLCMediaPlayer.m` calls
`IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep` every time
the player state becomes `Playing`, and releases it on any other state. The
behavior is macOS only and unconditional. No header exposes a way to turn it
off, and the assertion id is a file static, so one player blocks display sleep
for the whole process.

This is not libvlc. `--disable-screensaver=0` works, and it does stop libvlc
loading its own `iokit_inhibit` module, but VLCKit's assertion survives it.

VLCKit 3.7.3 carries none of this code. The move to 4.0 is what introduced it,
and 4.0 is needed for the telephoto lens. See
[ADR 0002](0002-vendor-vlckit-3-7-3.md).

## Decision

Replace the implementation of `preventDisplaySleep` with one that does nothing,
through the Objective-C runtime, before any player is built.

Leave `allowDisplaySleep` alone. It returns early when no assertion is held.

When the method is absent, as on VLCKit 3.x, do nothing. That build holds no
assertion.

`DisplaySleepTests` calls `preventDisplaySleep` on a real `VLCMediaPlayer` and
counts this process's assertions with `IOPMCopyAssertionsByProcess`. The test
asserts against a real count, not against a flag, because a flag would still
read true if VLCKit changed underneath.

## Consequences

- The app holds no assertion with every tile playing. Measured 2026-09-06.
- The app depends on a private selector. A rename in VLCKit makes the app block
  display sleep again, and it fails quietly rather than loudly.
- The test is the only thing that catches such a rename. It must keep asserting
  against real assertion counts.
- Every player in the process is covered, because the method belongs to the
  class and the assertion id is shared.

## Alternatives

- Stay on VLCKit 3.7.3. It holds no assertion, and it cannot play the telephoto
  lens.
- Release the assertion after each transition to playing, rather than stopping
  it being taken. That races VLCKit on every state change and leaves a window
  where the assertion is held.
- Patch and rebuild VLCKit. It removes the private-selector risk and adds a
  fork of a large dependency to maintain.
- Report it upstream and wait. Worth doing as well, but it does not make the app
  work today.
