# ReolinkVideo

VLCKit 4.0, behind the `VideoPlayer` protocol. See
[ADR 0001](../../docs/adr/0001-vlckit-behind-a-videoplayer-protocol.md) and the
amendment on [ADR 0002](../../docs/adr/0002-vendor-vlckit-3-7-3.md).

The app was on VLCKit 3.7.3 until 2026-09-06. It moved to 4.0 because the
telephoto lens of the TrackMix arrives as HEVC inside FLV, which needs
libavformat 60.16 or later. 3.7.3 carries 58.76 and adds the video track as
`undf`.

## Building the library

The headers are at
`Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A/Headers/`.

| Header | Declaration | Used |
|---|---|---|
| `VLCLibrary.h` | `- (instancetype)initWithOptions:(NSArray *)options;` | yes |
| `VLCMediaPlayer.h` | `- (instancetype)initWithOptions:(NSArray *)options;` | no |

`VLCMediaPlayer(options:)` makes a new libvlc instance for each player. With
three tiles that is three instances. `VLCLibraryHost` makes one `VLCLibrary`
instead, and each `VLCMediaPlayer` is built from it with
`VLCMediaPlayer(library:)`.

`VLCLibrary.sharedLibrary()` accepts no options. Do not use it.

The options are in `VLCLibraryHost.options`:

```
--disable-screensaver=0
--rtsp-tcp
--no-video-title-show
--no-snapshot-preview
--verbose=0
```

Library options take the `--` form. Per-media options take the `:` form, and
`VLCVideoPlayer` adds `:rtsp-tcp` and `:network-caching=300` to each `VLCMedia`.

## Two separate things hold a display assertion

The app exists so that video on screen does not block display sleep. On VLCKit
4.0 there are two mechanisms, and they are unrelated.

### libvlc's own inhibit module

libvlc 4.0 made `disable-screensaver` an integer, with 0 for never, 2 for
fullscreen, and 1 for always. The default is 1.

`--no-disable-screensaver` is a 3.x spelling. libvlc 4.0 rejects it, and a
rejected option stops the library initialising at all:

```
Error: Unknown option `--no-disable-screensaver'
*** Terminating app ... reason: 'libvlc failed to initialize'
```

`--disable-screensaver=0` is the accepted form. It works: `src/video_output/window.c`
creates the inhibitor only when the value is above zero, and the module never
loads.

### VLCKit's own assertion

This one is not libvlc, and no libvlc option reaches it. `VLCMediaPlayer.m` in
VLCKit does this, macOS only and unconditionally:

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
exposes a switch, and the assertion id is a file static, so one player is enough
to block display sleep for the process.

`DisplaySleep.stopVLCKitHoldingAssertions()` replaces that method with one that
does nothing, before any player is built. See
[ADR 0010](../../docs/adr/0010-neutralise-vlckit-display-sleep-assertion.md).

VLCKit 3.7.3 carries none of this code, and imports no `IOPMAssertion` symbol at
all, which is why the early measurements on that build were clean.

## What the binary shows

```bash
cd Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Versions/A

strings -a VLCKit | grep -oE "Lavf[0-9.]+" | sort -u   # Lavf63.1.100
nm -arch arm64 -u VLCKit | grep IOPMAssertion          # 3 symbols on 4.0, none on 3.7.3
strings -a VLCKit | grep -E "preventDisplaySleep"      # present on 4.0 only
```

## How to verify

Start the app, play every tile, and check that it owns no display assertion:

```bash
pid=$(pgrep -f "ReoView.app/Contents/MacOS/reoview")
pmset -g assertions | grep -E "pid ${pid}\b"
```

That must print nothing. A browser playing video at the same time prints lines
like `NoDisplaySleepAssertion named: "Video Wake Lock"`.

To watch it over time:

```bash
pmset -g assertionslog
```

### Result, 2026-09-06

Measured against the real NVR, with all three tiles playing: one H.264 sub
stream, one H.265 sub stream, and the telephoto lens over FLV. The app held no
assertion of any kind. Vivaldi, playing video at the same moment, held three.

## Tests

Run them with `scripts/test.sh`, not `swift test`.

SwiftPM merges every test target into one bundle and does not copy a binary
target's framework into it. VLCKit's install name is
`@loader_path/../Frameworks/VLCKit.framework/...`, which no rpath can redirect,
so the bundle cannot load it:

```
Library not loaded: @loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit
```

`scripts/test.sh` links the framework into the bundle, then runs the tests.

`DisplaySleepTests` is the guard on the countermeasure above. It calls
`preventDisplaySleep` on a real `VLCMediaPlayer` and counts this process's
assertions through `IOPMCopyAssertionsByProcess`. It asserts against a real
count rather than a flag, because a flag would still read true if VLCKit renamed
the method underneath.
