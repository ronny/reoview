#!/usr/bin/env bash
# Downloads VLCKit and extracts it into Vendor/. See docs/adr/0002-vendor-vlckit-3-7-3.md.
set -euo pipefail

VLCKIT_VERSION="3.7.3"
VLCKIT_ARCHIVE="VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/prod/${VLCKIT_ARCHIVE}"
VLCKIT_SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

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
  echo "Downloading VLCKit ${VLCKIT_VERSION} (about 88 MB)"
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
tar -xJf "${archive}" -C "${work}"

rm -rf "${xcframework}"

found_xcframework="$(find "${work}" -maxdepth 4 -name 'VLCKit.xcframework' -type d | head -1)"
if [[ -n "${found_xcframework}" ]]; then
  cp -R "${found_xcframework}" "${xcframework}"
else
  # The archive ships a plain framework. Wrap it so that SwiftPM can consume it.
  found_framework="$(find "${work}" -maxdepth 4 -name 'VLCKit.framework' -type d | head -1)"
  if [[ -z "${found_framework}" ]]; then
    echo "No VLCKit.framework or VLCKit.xcframework in ${VLCKIT_ARCHIVE}" >&2
    find "${work}" -maxdepth 3 >&2
    exit 1
  fi
  xcodebuild -create-xcframework \
    -framework "${found_framework}" \
    -output "${xcframework}"
fi

echo "VLCKit ${VLCKIT_VERSION} ready at ${xcframework}"
