# 0005. Typed commands and parsed capabilities

Status: accepted, 2026-09-06

## Context

Reolink's JSON is not uniform. Responses use `value` or `initial`. Errors carry a
numeric `rspCode`. Some fields arrive as an array with one element.

`reolink_aio` is the reference for every payload. Field names must be copied from
it, not guessed.

`GetAbility` returns per-channel ability versions. Two of them are already
needed: `supportAutoTrackStream` finds the telephoto lens, and the presence of
`GetEvents` picks the polling strategy.

## Decision

Define a `NVRCommand` protocol with an associated `Response: Decodable`. Write
one struct per command. `NVRClient.send(_:)` returns the typed response.

Decode `GetAbility` into a `Capabilities` value. Gate every control on it.

`ReolinkError` keeps the numeric `rspCode` rather than flattening it to a
message. Code `-6` means a bad token, and [ADR 0004](0004-strict-concurrency-and-a-serialised-nvr-client.md)
branches on it.

## Consequences

- Each response quirk is handled once, in one place, not at every call site.
- The `Transport` seam stays simple. It moves `Data`, not types.
- A new command is a new struct. The client does not change.
- The `Capabilities` struct is needed for stream discovery anyway, so gating the
  UI on it is free.

## Alternatives

- A generic `call(cmd:param:)` that returns raw JSON, with hand-written field
  reads. The quirks then spread through the app.
- Hardcode the controls for the two known cameras. It works on this NVR only.
- Show every control and hide it when its command fails. Controls then appear and
  vanish on first use.
