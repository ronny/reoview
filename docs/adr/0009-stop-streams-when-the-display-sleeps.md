# 0009. Stop streams when the display sleeps

Status: accepted, 2026-09-06

## Context

The app exists so that the display can sleep while video is on screen. See
[ADR 0001](0001-vlckit-behind-a-videoplayer-protocol.md).

The NVR limits the number of concurrent streams per channel, usually between four
and eight. Home Assistant and go2rtc also take streams. The machine is asleep for
much of the day.

## Decision

On `NSWorkspace.screensDidSleepNotification`, stop every player. Do not pause
them. On wake, open them again through the normal reconnect path.

Window occlusion uses the same handler.

## Consequences

- Sleep frees the RTSP sessions, so other clients keep working overnight.
- The reconnect path runs at least once a day, so a fault in it is found early.
- Video takes a few seconds to appear after wake.

## Alternatives

- Pause the players and hold the sessions open. Video returns faster, and the
  NVR holds sessions for a machine that is asleep.
- Leave the players running. It wastes CPU, network, and NVR sessions for no
  gain.
