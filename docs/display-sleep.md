# Display sleep — measurements

The app exists so that video on screen does not block display sleep. See
[ADR 0001](adr/0001-vlckit-behind-a-videoplayer-protocol.md).

Measured on 2026-09-06 on Mac `tiny`, macOS 26.6.2, with VLC 3.x from
`/Applications/VLC.app`. VLC embeds the same libvlc that VLCKit wraps.

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

## Still to prove

The probe decoded H.264 from a local file. A camera sends H.265 over RTSP, which
is a different decode path. Repeat this measurement against the real app and a
real stream in milestone 1.
