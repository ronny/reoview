# ReolinkVideo

VLCKit 3.7.3, behind the `VideoPlayer` protocol. See
[ADR 0001](../../docs/adr/0001-vlckit-behind-a-videoplayer-protocol.md).

## The screensaver option

VLCKit 3.7.3 has two ways to pass libvlc options. The headers are at
`Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Headers/`.

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
--no-disable-screensaver
--rtsp-tcp
--no-video-title-show
--no-snapshot-preview
--verbose=0
```

Library options take the `--` form. Per-media options take the `:` form, and
`VLCVideoPlayer` adds `:rtsp-tcp` and `:network-caching=300` to each `VLCMedia`.

## What the binary shows

The vendored libvlc has the `disable-screensaver` option, so
`--no-disable-screensaver` is valid:

```bash
cd Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework
strings -a VLCKit | grep -x disable-screensaver
```

It has no inhibit module compiled in. There is no `IOPMAssertionCreateWithName`
import and no `vlc_entry__inhibit_*` plugin:

```bash
nm -arch arm64 -u VLCKit | grep -c IOPMAssertion          # 0
nm -arch arm64 VLCKit | grep _vlc_entry_ | grep -i inhibit # empty
```

This build therefore takes no display assertion, with or without the option. The
option stays because it states the intent and it protects against a later
VLCKit that does ship the module.

## How to verify

Start the app, play a tile, and check that the app owns no display assertion:

```bash
pmset -g assertions | grep -i -A2 display
pmset -g assertions | sed -n '/Listed by owning process/,$p' | grep -i reolink
```

The second command must print nothing. A browser playing the same camera prints
a line like `NoDisplaySleepAssertion named: "Video Wake Lock"`.

To watch it over time:

```bash
pmset -g assertionslog
```

### Result, 2026-09-06

Verified with a local file, not a camera. A test clip came from
`ffmpeg -f lavfi -i testsrc=size=640x360:rate=25 -t 60 -c:v libx264 -pix_fmt yuv420p test.mp4`.
A small program built the library the same way `VLCLibraryHost` does, played the
clip into a `VLCVideoView` in a window, and ran `pmset -g assertions` after six
seconds of playback.

The process held no assertion. `Vivaldi`, playing video at the same time, held
three `NoDisplaySleepAssertion` entries named "Video Wake Lock". Playback with
the libvlc default (inhibition on) gave the same result, which agrees with the
missing inhibit module.

A camera still has to be checked, because RTSP and H.265 use a different decode
path.

## Tests

`swift test` fails to load the test bundle until the framework is in place.
SwiftPM copies a binary framework into a test bundle only when the test target
depends on the binary target, and `ReolinkVideoTests` depends on `ReolinkVideo`
only:

```
Library not loaded: @loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit
```

Add `"VLCKit"` to the `ReolinkVideoTests` dependencies in `Package.swift` to fix
it. Until then, make the link by hand after each clean build:

```bash
D=.build-video/arm64-apple-macosx/debug
mkdir -p $D/ReoViewPackageTests.xctest/Contents/Frameworks
ln -sfn ../../../VLCKit.framework \
  $D/ReoViewPackageTests.xctest/Contents/Frameworks/VLCKit.framework
```

SwiftPM also warns that this file is unhandled. Add
`exclude: ["README.md"]` to the `ReolinkVideo` target in `Package.swift` to
silence it.
