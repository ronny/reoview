# 0004. Strict concurrency and a serialized NVR client

Status: accepted, 2026-09-06

## Context

VLCKit is Objective-C and is not `Sendable`. Its delegate callbacks arrive on
internal threads.

Reolink HTTP stacks are fragile under concurrent requests. The NVR also caps the
number of concurrent API sessions, so a burst of simultaneous logins is a real
failure mode. The API body is a JSON array of commands, so one request can carry
many commands.

A later migration to strict concurrency is a large and unpleasant change.

## Decision

Use the Swift 6 language mode with strict concurrency from the first commit.

`NVRClient` is an `actor`. It holds one HTTP request in flight at a time.
Parallelism comes from batching many `{cmd}` objects into one POST.

Token refresh lives inside `NVRClient` as a single-flight method. Concurrent
commands that meet an expired token all await one login.

Everything that the UI observes is `@MainActor`. State uses `@Observable`, not
`ObservableObject`. VLCKit is wrapped in a `@MainActor` type, with narrow
`@unchecked Sendable` shims where the Objective-C API needs them.

## Consequences

- One afternoon of shims around VLCKit, and no migration later.
- Callers cannot assume parallel commands. They batch instead.
- Single-flight token refresh falls out of the actor. It needs no extra machinery.

## Alternatives

- Swift 5 mode with `ObservableObject` and `DispatchQueue.main.async`. Cheaper
  now, and a rewrite later.
- A retry decorator around `Transport` for token refresh. A decorator cannot do
  single-flight, because it does not know about `Login`.
