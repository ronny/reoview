#!/usr/bin/env bash
# Runs the test suite.
#
# SwiftPM merges every test target into one bundle, and it does not copy a
# binary target's framework into that bundle. VLCKit's install name is
# @loader_path/../Frameworks/VLCKit.framework/..., which no rpath can redirect,
# so the bundle cannot load it. Link the framework into place, then test.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

scratch="${SCRATCH_PATH:-.build}"
config="debug"

swift build --scratch-path "${scratch}" --build-tests "$@"

bundle="$(find "${scratch}" -maxdepth 3 -name '*PackageTests.xctest' -type d | head -1)"
if [[ -z "${bundle}" ]]; then
  echo "error: no test bundle under ${scratch}" >&2
  exit 1
fi

framework="$(cd "$(dirname "${bundle}")" && pwd)/VLCKit.framework"
if [[ -d "${framework}" ]]; then
  mkdir -p "${bundle}/Contents/Frameworks"
  ln -sfn "${framework}" "${bundle}/Contents/Frameworks/VLCKit.framework"
fi

swift test --scratch-path "${scratch}" "$@"
