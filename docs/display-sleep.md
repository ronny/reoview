# Display sleep — measurements

The app exists so that video on screen does not block display sleep. See
[ADR 0001](adr/0001-vlckit-behind-a-videoplayer-protocol.md).

Measured on 2026-09-06 on Mac `tiny`, macOS 26.6.2. The first experiment used
VLC 3.x from `/Applications/VLC.app`, which embeds the same libvlc that VLCKit
wraps. Later sections measure the app itself, on VLCKit 3.7.3 and then on 4.0.

## Method

```bash
ffmpeg -y -f lavfi -i testsrc=size=1280x720:rate=25 -t 120 \
  -c:v libx264 -pix_fmt yuv420p testclip.mp4

/Applications/VLC.app/Contents/MacOS/VLC [OPTIONS] --loop testclip.mp4 &
sleep 8
pmset -g assertions | grep -i VLC
```

## Results

Without `--no-disable-screensaver`:

```
NoDisplaySleepAssertion named: "VLC media playback"
UserIsActive named: "VLC media playback"
```

With `--no-disable-screensaver`:

```
NoIdleSleepAssertion named: "VLC media playback"
```

## Reading

The option removes the display assertion and the `UserIsActive` assertion. This
is the behavior the app needs.

One assertion remains. `NoIdleSleepAssertion` blocks system idle sleep. It does
not block display sleep. On a machine that runs the app full time, system sleep
is not wanted either way.

The original plan asked for an empty assertion list for the app process. That is
not what happens. The list is not empty, but it holds nothing that keeps the
display awake.

## Confirmation of the problem

The same command showed the browser side of the problem. Vivaldi held three
assertions while a video played in a tab:

```
NoDisplaySleepAssertion named: "Video Wake Lock"
```

## VLCKit 3.7.3 holds no display assertion

VLC.app adds an AppKit layer above libvlc. VLCKit does not. Two checks on the
vendored binary at `Vendor/VLCKit.xcframework`:

```bash
cd Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework
strings -a VLCKit | grep -x disable-screensaver     # present
nm -arch arm64 -u VLCKit | grep IOPMAssertion       # no results
```

The option string is present, so `--no-disable-screensaver` is valid for this
build. No `IOPMAssertion` symbol is imported, and no `inhibit` plugin is
compiled in. Only `vlc_inhibit_Create` is present, which is the core no-op shim.
VLCKit 3.7.3 therefore cannot take a display assertion.

A probe program built the library the same way `VLCLibraryHost` does, played the
test clip into a `VLCVideoView` in a window, and read `pmset -g assertions` after
6 seconds of playback. The probe held no assertion. Vivaldi held three at the
same moment.

## VLCKit 4.0 holds its own assertion

The app moved to VLCKit 4.0 to play the telephoto lens. That build brings back
the problem, from a place no libvlc option reaches.

`VLCMediaPlayer.m` in VLCKit itself does this, macOS only and unconditionally:

```objc
- (void)mediaPlayerStateChanged:(const VLCMediaPlayerState)newState {
    if (newState == VLCMediaPlayerStatePlaying) {
        [self preventDisplaySleep];
    } else {
        [self allowDisplaySleep];
    }
}
```

`preventDisplaySleep` calls `IOPMAssertionCreateWithName` with
`kIOPMAssertionTypeNoDisplaySleep`, named "VLC Media Playback". No header
exposes a switch for it, and the assertion id is a file static, so it is shared
by every player in the process.

Three facts about libvlc options, none of which help:

- libvlc 4.0 changed `disable-screensaver` from a boolean to an integer, with
  the values 0 for never, 2 for fullscreen, and 1 for always. The default is 1.
- `--no-disable-screensaver` is therefore rejected, and a rejected option stops
  libvlc initialising at all. `--disable-screensaver=0` is the accepted form.
- That option does work. It stops libvlc loading its own `iokit_inhibit`
  module. It has no effect on the assertion above, which is not libvlc's.

VLCKit 3.7.3 carries none of this code, which is why the earlier measurements
were clean.

## The countermeasure

`DisplaySleep.stopVLCKitHoldingAssertions()` replaces the implementation of
`preventDisplaySleep` with one that does nothing, before any player is built.
`allowDisplaySleep` is left alone, because it returns early when no assertion is
held. On VLCKit 3.x the method does not exist and the call does nothing.

`DisplaySleepTests` guards it by calling the method on a real `VLCMediaPlayer`
and counting this process's assertions through `IOPMCopyAssertionsByProcess`.

## Confirmed against the real app, 2026-09-06

On VLCKit 3.7.3 the app played two RTSP streams from the NVR, one H.264 and one
H.265, and held no assertion. On VLCKit 4.0, with all three tiles playing and
`preventDisplaySleep` neutralised, the result is the same:

```
app pid 84636: no assertion of any kind
pid 31227(Vivaldi): NoDisplaySleepAssertion named: "Video Wake Lock"   x3
```

The gate in ADR 0001 is met. The app holds nothing, while a browser playing
video on the same machine holds three display assertions.

The `VLCParams` key was present during this measurement, with the screensaver
option written into it by the app.

## VLCParams in user defaults

VLCKit reads an array named `VLCParams` from `NSUserDefaults` and uses it
instead of the options passed to `VLCLibrary(options:)`. Nothing in this
repository writes that key, and the app's defaults domain holds one after the
first run:

```bash
defaults read au.ronny.ReoView VLCParams
```

A stored array therefore discards every option the app sets, silently.

This was harmless on VLCKit 3.7.3, which held no assertion whatever the options
said. On 4.0 it is not harmless, so `VLCLibraryHost.enforceOptionsInUserDefaults`
rewrites the key before the library is built. It keeps VLCKit's own entries and
replaces the screensaver one.

Note that this only governs the libvlc option. The assertion VLCKit takes in its
own Objective-C layer is unaffected by anything in this array.

## What can still break this

The countermeasure replaces a private method, `VLCMediaPlayer.preventDisplaySleep`.
Nothing in VLCKit's headers promises it exists.

If a future VLCKit renames or removes it, `DisplaySleep` finds no method and
does nothing. The app then blocks display sleep again, and it does so quietly:
there is no crash and no error. `DisplaySleepTests` is the only thing that
catches it, which is why it counts real assertions through
`IOPMCopyAssertionsByProcess` rather than trusting a flag.

Re-run the measurement above after any VLCKit upgrade.
