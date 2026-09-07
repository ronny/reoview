# Credits

ReoView itself is under the Apache License 2.0. See [LICENSE](LICENSE).

This file lists everything else: what ships inside the app, what the app was
built from, and what was read to learn how the cameras speak. Each entry says
what the licence asks of anyone who redistributes the result.

## Ships inside the application

### VLCKit

- Upstream: [videolan/vlckit](https://code.videolan.org/videolan/VLCKit)
- Version: 4.0, build `4.0-20260831-1526`
- Licence: **GNU Lesser General Public License, version 2.1 or later**
- Copyright: VideoLAN and VLC authors

VLCKit decodes and displays every stream. It is downloaded by
`scripts/fetch-vlckit.sh`, is not modified, and is embedded in the application
bundle as a separate dynamic framework at
`ReoView.app/Contents/Frameworks/VLCKit.framework`.

**What the LGPL asks.** ReoView links VLCKit dynamically and does not modify it,
which is the arrangement section 6 of the LGPL permits. Anyone redistributing
ReoView must:

- keep this notice and the LGPL text that VideoLAN ships in the framework,
- leave the framework as a separate file that a user can replace, and
- point users at VideoLAN's source, which is at the address above.

The framework is a separate file in the bundle precisely so that a user can
swap in their own build of VLCKit. Do not merge it into the executable.

### Material Symbols

- Upstream: [google/material-design-icons](https://github.com/google/material-design-icons)
- Glyph: `nest_cam_iq_outdoor`, sharp, filled
- Licence: **Apache License 2.0**
- Copyright: Google

The application icon. The glyph is vendored at `Resources/AppIcon-glyph.svg` and
drawn onto a coloured plate by `scripts/make-icon-art.swift`.

The plate colour was sampled from Reolink's own application icon so that the two
sit together in the Dock. No Reolink mark, logo or wordmark is used, and ReoView
is not a Reolink product.

## Read while writing this, but not shipped

None of the following is distributed with ReoView. They were read to learn
protocol and payload details. Facts about a wire format are not copyrightable,
but attribution is owed where a specific implementation shaped the code.

### reolink_aio

- Upstream: [starkillerOG/reolink_aio](https://github.com/starkillerOG/reolink_aio)
- Licence: **MIT**

The reference for every HTTP payload: field names, which commands exist, how
responses are shaped, and which abilities gate which control. Reading it is why
the command layer works on the first try against a real device. Several places
where its behaviour contradicts the vendor documentation are recorded in
[docs/initial-context.md](docs/initial-context.md).

### neolink

- Upstream: [QuantumEntangledAndy/neolink](https://github.com/QuantumEntangledAndy/neolink)
- Licence: **AGPL-3.0**

Read as documentation for the Baichuan protocol on port 9000: message
identifiers, framing, and the shape of a talk session. **No code was copied.**
Two short remarks from its parser are quoted in comments where they explain a
field this project had to choose a value for.

Because nothing was copied, the AGPL does not reach ReoView. If you intend to
port code from neolink rather than read it, that changes.

### neolink.net

- Upstream: [borexola/neolink.net](https://github.com/borexola/neolink.net)
- Licence: see upstream

Read for a second opinion on two disputed BcMedia fields, and for its choice to
reconstruct the ADPCM predictor the way a decoder does. `BcMediaFrameRules`
names one of its cases after this implementation.

### reolens

- Upstream: [jestatsio/reolens](https://github.com/jestatsio/reolens)
- Licence: **MIT**
- Copyright: the reolens authors

A Swift Baichuan client. Its `Wire/Encryption.swift` was read as a correct
reference for deriving the session key and for AES-128-CFB through CommonCrypto,
which CryptoKit does not offer. Credited in `Sources/ReolinkBaichuan/BcCrypto.swift`.

### FFmpeg

- Upstream: [FFmpeg](https://ffmpeg.org)
- Licence: **LGPL-2.1-or-later** for `libavcodec/adpcmenc.c`

Used two ways, neither shipped:

1. The `ffmpeg` command line tool generated the reference ADPCM blocks checked
   into the test target, and the test clips used to measure display sleep.
   Generated output carries no licence obligation.
2. `Tests/ReolinkAudioTests/FFmpegIMAEncoder.swift` reimplements the quantiser
   in `libavcodec/adpcmenc.c` so that those reference blocks can be reproduced
   exactly, and so the difference from this project's encoder is visible and
   deliberate. See the note in that file.

**Point 2 deserves care.** That file was written by reading FFmpeg's source and
may be a derived work of LGPL code. It is test-only and never linked into the
application. Anyone redistributing this repository should treat that single file
as LGPL-2.1-or-later, or delete it: the checked-in reference blocks are data and
stand on their own.

## Apple frameworks

AVFoundation, AppKit, SwiftUI, Network, CommonCrypto, IOKit and Security are
used under the Apple SDK licence that comes with Xcode. Nothing from them is
redistributed.

## Not affiliated with Reolink

Reolink is a trademark of its owner. ReoView is an independent client, developed
by reading a public API and by measuring one NVR. It is not endorsed by, and
carries no code from, Reolink.
