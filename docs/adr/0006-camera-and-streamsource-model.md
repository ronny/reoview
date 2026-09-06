# 0006. Camera and StreamSource model

Status: accepted, 2026-09-06

## Context

The TrackMix has two lenses. Through an NVR, the second lens is an extra stream
name on the same channel, not an extra channel. A tile is therefore not the same
thing as a channel.

The RTSP path for main and sub streams needs a codec prefix that comes from
`GetEnc`. `reolink_aio` flips the codec and retries when the first URL fails. URL
construction is not a pure function.

The telephoto path has no codec prefix and no sub stream.

The channel index is not stable. A change of PoE port changes it.

## Decision

A `Camera` has many `StreamSource` values. A `StreamSource` is a camera, a lens,
and a quality. A tile shows one `StreamSource`.

`Camera.id` is the channel UID from `GetChannelstatus`, and falls back to
`"ch<N>"`. `StreamSource.id` is `"<camera id>/<lens>/<quality>"`. Saved layout,
mute state, and preferences all key on these ids.

Every command carries a `ChannelRef` of `{host, channel}`. In v1 the host is
always the NVR.

A `StreamResolver` returns an ordered list of candidate URLs for a
`StreamSource`: the preferred codec first, the flipped codec second, FLV last.
`PlayerController` walks the list on failure and caches the winner in
`AppConfig`.

## Consequences

- The two lenses need no special case in the UI.
- A wide-to-telephoto toggle on one tile is a small change if the third tile ever
  costs too much bandwidth.
- The player is the probe. No separate RTSP `DESCRIBE` client is needed.
- A future direct-to-camera connection needs no change to command signatures.

## Alternatives

- A tile per channel, with the telephoto special-cased. It breaks on the device
  that already exists.
- A hardcoded three-item list. The retrofit cost is the whole UI layer.
- An async resolver that probes with RTSP `DESCRIBE` before it returns one URL,
  as `reolink_aio` does. It doubles the RTSP session count during startup, on a
  device that rations sessions.

## Amendment, 2026-09-06

The model holds. The candidate order for the telephoto lens is now the reverse
of the rule above, and the FLV stream name in the context was wrong.

Measured against the RLN8-410 on firmware v3.6.5.562. `GetAbility` reports
`supportAutoTrackStream = 1` for channel 1, so the NVR knows about the second
lens. Every RTSP form of it answers 404 Stream Not Found: `Preview_02_autotrack`,
`h264Preview_02_autotrack`, and `h265Preview_02_autotrack`.

FLV serves the lens, under the name `ext`. `channel1_ext.bcs` streams video.
`channel1_autotrack.bcs` and `channel1_telephoto.bcs` do not connect. reolink_aio
would build `channel1_telephoto_main.bcs`, which also answers nothing, so the
name did not come from there.

The telephoto candidate list is FLV first, then the RTSP path. Other firmware may
carry the lens over RTSP, so the RTSP form stays as a later candidate rather than
being removed.

The wide lens is unchanged: RTSP first, FLV last.
