#!/usr/bin/env bash
# Downloads VLCKit and extracts it into Vendor/. See docs/adr/0002-vendor-vlckit-3-7-3.md.
set -euo pipefail

VLCKIT_VERSION="4.0-20260831-1526"
VLCKIT_ARCHIVE="VLCKit-4.0-20260831-1526.zip"
VLCKIT_URL="https://download.videolan.org/cocoapods/unstable/${VLCKIT_ARCHIVE}"
# The same checksum the official master Package.swift pins.
VLCKIT_SHA256="c61a42052ec4c1315325fba81f8893f4ccf639d92bf61dd1b3c37c3a2f26b8e3"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor_dir="${repo_root}/Vendor"
cache_dir="${vendor_dir}/.cache"
xcframework="${vendor_dir}/VLCKit.xcframework"

if [[ -d "${xcframework}" && "${1:-}" != "--force" ]]; then
  echo "VLCKit ${VLCKIT_VERSION} already present at ${xcframework}"
  exit 0
fi

mkdir -p "${cache_dir}"
archive="${cache_dir}/${VLCKIT_ARCHIVE}"

if [[ ! -f "${archive}" ]]; then
  echo "Downloading VLCKit ${VLCKIT_VERSION} (about 900 MB)"
  curl -fL --progress-bar -o "${archive}.partial" "${VLCKIT_URL}"
  mv "${archive}.partial" "${archive}"
fi

echo "Verifying checksum"
actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
if [[ "${actual}" != "${VLCKIT_SHA256}" ]]; then
  echo "Checksum mismatch for ${VLCKIT_ARCHIVE}" >&2
  echo "  expected ${VLCKIT_SHA256}" >&2
  echo "  actual   ${actual}" >&2
  exit 1
fi

echo "Extracting"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
unzip -q -o "${archive}" -d "${work}"

rm -rf "${xcframework}"

# The published xcframework carries every Apple platform and 462 MB of dSYMs.
# Keep the macOS framework only and rebuild a single-platform xcframework
# around it, which is all this app links.
macos_framework="$(find "${work}" -maxdepth 4 -path '*macos*' -name 'VLCKit.framework' -type d | head -1)"
if [[ -n "${macos_framework}" ]]; then
  xcodebuild -create-xcframework \
    -framework "${macos_framework}" \
    -output "${xcframework}" > /dev/null
else
  echo "No macOS VLCKit.framework in ${VLCKIT_ARCHIVE}" >&2
  find "${work}" -maxdepth 3 >&2
  exit 1
fi

echo "VLCKit ${VLCKIT_VERSION} ready at ${xcframework}"
