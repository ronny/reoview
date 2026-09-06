# 0008. Batched GetEvents polling in a shared poller

Status: accepted, 2026-09-06

## Context

`GetEvents` returns motion, AI detection, and doorbell visitor state for one
channel in one response. It replaces `GetMdState` and `GetAiState`. The doorbell
visitor state is available over plain HTTP, so notifications do not need
Baichuan.

The API body is a JSON array, so one POST can ask for every channel at once.
`reolink_aio` does exactly this.

[ADR 0004](0004-strict-concurrency-and-a-serialised-nvr-client.md) serializes the
client to one request in flight.

## Decision

One `EventPoller` actor issues a single batched POST that carries `GetEvents` for
every channel. It polls every 1 to 2 seconds while the window is visible. It
stops on window occlusion and on display sleep.

`GetAbility` says whether `GetEvents` exists. When it does not, the poller falls
back to `GetMdState` and `GetAiState` in the same batch.

This is a deliberate difference from the per-camera ownership in
[ADR 0006](0006-camera-and-streamsource-model.md). Video state is per camera
because video fails per camera. Event state is one round trip for all channels,
so one owner is correct.

## Consequences

- One request per poll, whatever the number of cameras.
- The poll is easy to stop and start in one place.
- The ownership split between video and events is not an inconsistency. It is
  recorded here so that it is not "corrected" later.

## Alternatives

- A poll inside each `PlayerController`. It multiplies the request count against
  a device that is fragile under concurrency.
- Poll only the selected tile. The status strip then shows stale dots for the
  other cameras.
- Baichuan push events. That is a protocol port, and it is out of scope for v1.

## Amendment, 2026-09-06

The decision holds. One fact in the context above is wrong.

`GetAbility` carries no ability key for `GetEvents`. reolink_aio finds the
command by sending it once and looking for a response element that is not an
error. See `check_command_exists` in `reolink_aio/api.py`.

`Capabilities.supportsGetEvents` therefore reports false until a probe records
a result. The poller must probe once at startup, then choose between `GetEvents`
and the pair of `GetMdState` and `GetAiState`.
