# ReoView — initial context

A small native macOS app that shows the cameras on a Reolink NVR. It replaces
the Reolink macOS app and a Home Assistant "Cameras" dashboard.

The app exists for one reason. Browsers hold a `NoDisplaySleep` power assertion
for any visible playing `<video>`. A web page cannot turn this off. A native
player can. See [ADR 0001](adr/0001-vlckit-behind-a-videoplayer-protocol.md)
and [ADR 0009](adr/0009-stop-streams-when-the-display-sleeps.md).

This file holds the domain model and the device findings. They were expensive to
measure, and most of them are not in any vendor document.

## Vocabulary

One word, one meaning. These names appear in the code as written here.

| Term | Meaning |
|---|---|
| NVR | The Reolink recorder. The only host the app talks to in v1. |
| Channel | An NVR slot. 0-based in the HTTP API, 1-based in RTSP paths. |
| `ChannelRef` | A `{host, channel}` pair. Every command carries one. |
| Camera | A physical device on a channel. |
| Lens | `wide` or `telephoto`. The TrackMix has both. The doorbell has `wide` only. |
| Quality | `main` or `sub`. |
| `StreamSource` | One playable feed: camera, lens, and quality together. |
| Tile | One `StreamSource` shown in the grid. |
| `Capabilities` | The parsed `GetAbility` response. Gates every control. |
| `Transport` | The seam under `NVRClient`. Data in, data out. |
| `VideoPlayer` | The seam under the video engine. |
| `PlayerController` | Per-tile state machine. Owns its own reconnect backoff. |
| `EventPoller` | Shared owner of the `GetEvents` poll. |
| `AppConfig` | The persisted configuration. Carries a schema version. |

Identity is stable across NVR re-cabling:

- `Camera.id` is the channel UID from `GetChannelstatus`. It falls back to
  `"ch<N>"` when the UID is absent.
- `StreamSource.id` is `"<camera id>/<lens>/<quality>"`.

The channel index is deliberately not an identity. A change of PoE port changes
the index but not the UID.

## What the findings were measured against

Every measurement in this file was taken on 2026-09-06 against this hardware.
Another firmware may answer differently.

| Item | Value |
|---|---|
| NVR | Reolink RLN8-410, firmware v3.6.5.562 |
| HTTPS API | Port 443, self-signed certificate |
| RTSP | Port 554 |
| Baichuan | Port 9000. Carries two-way talk. |
| Channel 0 | Reolink Video Doorbell PoE. Main stream is H.264. One lens. |
| Channel 1 | Reolink TrackMix PoE. Main stream is H.265. Two lenses. |

`<nvr-host>` below stands for the address of the NVR.

## Stream URLs

Payload shapes come from `starkillerOG/reolink_aio` (`reolink_aio/api.py`), read
on 2026-09-06. Copy field names from that file. Do not guess them.

Main and sub streams need a codec prefix. The codec comes from `GetEnc`, field
`vType`:

```
rtsp://<user>:<percent-encoded password>@<nvr-host>:554/<h264|h265>Preview_<NN>_<main|sub>
```

`NN` is the channel index plus one, with two digits. When the first URL fails,
reolink_aio flips the codec and tries again. The app does the same through an
ordered candidate list. See [ADR 0006](adr/0006-camera-and-streamsource-model.md).

The last-resort candidate is FLV over HTTP:

```
https://<nvr-host>/flv?port=1935&app=bcs&stream=channel<N>_<stream>.bcs&user=<user>&password=<password>
```

RTSP needs the password percent-encoded. Every character outside the RFC 3986
unreserved set is escaped, which is `quote(password, safe="")` in reolink_aio.

FLV is different. reolink_aio says "FLV needs unencoded password" and sends it
raw. A raw password can also make a URL that will not parse, so the resolver
emits both forms as separate candidates, raw first.

### The telephoto lens

The telephoto lens exists when `GetAbility` reports `supportAutoTrackStream > 0`
for that channel. Through an NVR the second lens is an extra stream name on the
same channel, not an extra channel.

RTSP does not carry the telephoto lens. Measured with
`supportAutoTrackStream = 1` on channel 1:

| Path | Result |
|---|---|
| `Preview_02_autotrack` | 404 Stream Not Found |
| `h264Preview_02_autotrack` | 404 Stream Not Found |
| `h265Preview_02_autotrack` | 404 Stream Not Found |

FLV carries it. The stream name is `ext`, not `autotrack` or `telephoto`:

| FLV stream | Result |
|---|---|
| `channel1_ext.bcs` | 200, streams video |
| `channel1_autotrack.bcs` | no connection |
| `channel1_telephoto.bcs` | no connection |

The telephoto candidate list therefore puts FLV first and keeps the RTSP form
last, in case other firmware serves it.

### The telephoto lens needs VLCKit 4.0

The FLV carries HEVC. VLCKit 3.7.3 cannot demux that combination:

| Stream | Container | Codec | VLC result |
|---|---|---|---|
| `channel1_ext.bcs` | FLV | HEVC 1920x1080 | `undf (0)` on 3.7.3, plays on 4.0 |
| `channel1_sub.bcs` | FLV | H.264 896x512 | plays on both |

HEVC inside FLV is the enhanced-RTMP extension. It needs libavformat 60.16 or
later, which is FFmpeg 6.1. Recent ffmpeg reads it, and `ffprobe` names the
codec correctly. The older ffmpeg inside VLCKit 3.7.3 does not, so it adds the
video track as `undf` and never finds a decoder. Audio decodes, which is why the
tile connects and then stays black.

The data is good and the decoder is good. Only the demuxer is at fault:

```bash
ffmpeg -f flv -i channel1_ext.flv -c copy -f mpegts ext.ts
```

VLC plays `ext.ts` with VideoToolbox.

Three facts close off the easy answers:

- `GetEnc` on channel 1 returns `mainStream` and `subStream` only. There is no
  `extStream`, so the encoding of the telephoto lens cannot be changed to H.264.
- Only the NVR answers on the LAN. An ARP sweep of the subnet finds one Reolink
  MAC address. The cameras sit behind the PoE ports of the NVR, so a direct
  connection to the TrackMix is not reachable.
- Plain HTTP is not available. Port 80 redirects to HTTPS.

The app moved to VLCKit 4.0, which carries libavformat 63.1 and plays the lens.
See the amendment on [ADR 0002](adr/0002-vendor-vlckit-3-7-3.md).

## Events

`GetEvents` returns motion, AI detection, and doorbell visitor state for one
channel in one response. It replaces `GetMdState` and `GetAiState`. The doorbell
visitor state is therefore available over plain HTTP. Baichuan is not needed for
notifications.

`GetEvents` reports `md`, the `ai` detections, and `visitor` for one channel.
`md` carries no `support` key, so motion counts as supported when it is absent.
`visitor` does carry `support`, so it is a reliable test for whether a channel
is a doorbell.

There is no ability key for `GetEvents`. reolink_aio finds it by sending the
command once and looking for a response element that is not an error
(`check_command_exists`). `Capabilities.supportsGetEvents` is therefore false
until that probe records a result. When the command is absent, fall back to
`GetMdState` and `GetAiState`.

## Control commands

Payloads came from `reolink_aio`, not from a summary table. The summary was
wrong or incomplete in every subject below. Each row is verified against
`reolink_aio/api.py` and the `GetAbility` response of the NVR.

| Subject | What is true |
|---|---|
| Siren | `{alarm_mode:"manul", manual_switch:0\|1}` holds it on or off. `{alarm_mode:"times", times:N}` plays a fixed count. The two never appear together. "manul" is Reolink's spelling. |
| PTZ support | Gated on `ptzType`, not `ptzCtrl`. `reolink_aio` never reads `ptzCtrl`. A `ptzType` of `[2,3,5,6,7]` pans, `[2,3,5,6]` tilts, `[1,2,5]` has optical zoom. The TrackMix channel reports `ptzType` 3. |
| PTZ speed | Send `speed` only when the channel reports `supportPtzSpeed`. An absent key counts as supported. |
| Zoom | `GetZoomFocus` needs `action: 1` to return the range. On the TrackMix, zoom comes from `supportDigitalZoom`, not from the optical-zoom family. |
| Guard | `cmdStr` is `setPos` or `toPos`, lower case. `PtzCtrl` uses `ToPos`. Send `bSaveCurrentPos` only when saving the current position. |
| Channel placement | `SetPtzGuard`, `StartZoomFocus`, `SetWhiteLed`, `SetAudioCfg` and `SetManualRec` carry `channel` inside their wrapper object. The rest take it at the top level. |
| Manual record | No ability key exists. Start also sends `duration: 600`. An `enable` above 1 is a firmware bug that drains a battery camera. |
| Quick reply | `supportAudioPlay` does not exist on this NVR. The doorbell reports `supportQuickReplyPlay`. Check both. |
| Audio | `AudioAlarmPlay`, `GetAudioCfg` and `SetAudioCfg` have moved to Baichuan in current `reolink_aio`, but the HTTP forms still work on firmware v3.6.5.562. |
| Siren settings | `GetAudioAlarm` answers `rspCode -9`, "not support". This firmware uses `GetAudioAlarmV20`. Playing the siren with `AudioAlarmPlay` is unaffected. |

### Quick reply needs recorded clips

`GetAudioFileList` returns `{"AudioFileList": null}` on this NVR. The plumbing
works; there are simply no clips. The NVR stores and plays them but cannot
record them. Use the official Reolink mobile app to record a clip, after which
the list fills and the picker works with no change to this app.

`GetAutoReply` answers over HTTP and reports `enable`, `fileId` and `timeout`.

### Probed commands

Four commands have no ability key and must be probed, the same way `GetEvents`
is: send the Get command once and record the answer through
`Capabilities.recording(command:present:)`. They are `GetWhiteLed`,
`GetPtzGuard`, `GetAudioCfg` and `GetManualRec`. A transport failure says
nothing about whether a command exists, so it must not be recorded as absent.

## Settled details

These are decisions with a low reversal cost. They are recorded here, not as
ADRs.

- Minimum macOS is 14.0. Nothing in the app needs a later API.
- The app is named ReoView, to keep it apart from Reolink's own macOS app.
- The bundle identifier, the `os.Logger` subsystem, and the keychain service are
  all the same string. The executable is `reoview`.
- `AppConfig` is JSON in `UserDefaults` and carries a `version: Int`. A decode
  error logs and falls back to a fresh default. It must never crash the app.
- The password is a `kSecClassGenericPassword` item in the file keychain.
  Service is the bundle identifier. Account is `"<user>@<host>"`. The data
  protection keychain needs an embedded provisioning profile, which a Developer
  ID app does not get. Measured 2026-09-06: `SecItemAdd` returns -34018 without
  one, and a binary that claims `com.apple.application-identifier` without a
  profile is killed on launch.
- One dedicated NVR admin user serves both HTTP and RTSP. Do not reuse the user
  of another client. A rotation of that password must not break the other
  client.
- Every log statement redacts the password.
- `ReolinkError` keeps Reolink's numeric `rspCode`. Code `-6` means a bad token.
- Tiles start muted, and only one tile may be unmuted at a time.
- The standard grid shows the sub stream of every wide lens, then the main
  stream of a telephoto lens. A telephoto lens has no sub stream, so the grid
  mixes qualities.
- A dead tile retries itself and shows a per-tile overlay. A dead NVR shows one
  global banner and disables every control.
- No Sparkle yet. Release archives get a stable naming scheme, so a GitHub
  appcast can be added later without a change to the bundle.

## Local network permission

macOS 15 and later gate access to the local network per app. A denied or
ungranted app does not get a clear error: `URLSession` fails with
`NSURLErrorNotConnectedToInternet` (-1009), which reads as "the internet
connection appears to be offline" even though the NVR is one hop away.

Two things matter for the grant to stick:

- `NSLocalNetworkUsageDescription` in `Info.plist`. macOS 14 does not need it.
- A stable code signature. An ad-hoc signed app has no Team ID, so the grant
  cannot attach to a stable identity. A Developer ID signature fixes this.

The app appears in System Settings, Privacy and Security, Local Network once it
has tried to reach the NVR.

The grant arrives after the request that triggered it has already failed, so
something has to ask again once it is answered. `AppState.isLocalNetworkRefusal`
recognises the code and replaces the message with one that says what is actually
happening. Asking again is a button, never a timer: Connect in the setup wizard,
and Retry on the banner. An earlier build retried on a 2, 3, 5, 8, 13, 20 second
ladder, which the wizard makes redundant — the prompt is raised by a button
press, so there is someone there to press it again.

macOS exposes no way to read the local network grant, so the wizard reports the
only fact it has: whether the NVR answered.

## Permissions are asked for by a button

Three grants are needed, and macOS raises each prompt as a side effect of the
first call that needs it. Left alone, that puts unexplained system dialogs over
an empty window on a first run.

The setup wizard asks for all three instead, one row and one button each:

| Permission | Raised by | Optional |
|---|---|---|
| Local network | Reaching the NVR | No |
| Notifications | `UNUserNotificationCenter.requestAuthorization` | Yes |
| Microphone | `AVCaptureDevice.requestAccess(for: .audio)` | Yes |

Which is why the credentials come first: the local network prompt needs a host
to reach before it can be raised at all.

Nothing outside the wizard raises a prompt on its own. `VisitorNotifier.activate`
reads the standing answer and takes the delegate, and never asks. Push to talk
still asks for the microphone if the wizard was skipped, because that press is
a user action too.

A refusal cannot be asked for twice: the second call returns the stored answer
and shows nothing. The wizard swaps the button for one that opens the right
System Settings pane.

## Deferred, and why

- Recordings. `Search`, a date picker, FLV playback, and `Download`. When added,
  it gets its own `Window` scene, not a tab. Deferred because the official
  Reolink app covers it well enough.
- Privacy mode. It has no HTTP command. It needs Baichuan, which the app now
  speaks, so this is reachable rather than blocked.
- Push events. The app polls instead. This also needs Baichuan.
- A Home Assistant bridge.
- iOS and iPadOS.
