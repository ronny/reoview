# 0002. Vendor VLCKit 3.7.3 through a fetch script

Status: accepted, 2026-09-06

## Context

The official `videolan/vlckit` `Package.swift` exists only on `master`. It is a
`binaryTarget` that points at a VLCKit 4.0 alpha archive. The stable tags, up to
3.7.3, carry no `Package.swift`.

VideoLAN publishes prebuilt archives at
`download.videolan.org/pub/cocoapods/prod/`. `VLCKit-3.7.3` is dated 2026-02-25
and is about 88 MB. The 3.7.x line gets regular releases.

CocoaPods is not an option, because it needs an Xcode project. See
[ADR 0003](0003-build-without-xcode.md).

## Decision

A fetch script downloads the VLCKit 3.7.3 archive, compares its checksum against
a value committed in the repository, and extracts the xcframework into
`Vendor/`. `Package.swift` references it with `.binaryTarget(name:path:)`.

`Vendor/` is ignored by version control.

## Consequences

- The version is pinned exactly, and the artifact is the same one CocoaPods ships.
- A first build needs network access.
- The repository stays small. An 88 MB blob would make every clone slow.
- A later move to VLCKit 4.0 changes the fetch script and the VLCKit
  implementation of `VideoPlayer`. Nothing else.

## Alternatives

- The `master` SPM package. That is a 4.0 alpha under the one component the whole
  app depends on.
- A community SPM wrapper. It adds a third party between us and VideoLAN.
- Commit the extracted framework. GitHub warns above 50 MB per file.
