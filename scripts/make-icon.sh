#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from a source PNG. See docs/adr/0003-build-without-xcode.md.
set -euo pipefail

# A 16x16 solid swatch, #1F3A5F. sips can only transform an image, never create
# one, so the placeholder path decodes this and scales it up.
PLACEHOLDER_PNG_BASE64="iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mOQt4onCTGMahjVMHw1AACTh7gBWUCmdgAAAABJRU5ErkJggg=="

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resources_dir="${repo_root}/Resources"
default_png="${resources_dir}/AppIcon.png"
source_png="${1:-${default_png}}"
icns="${resources_dir}/AppIcon.icns"

mkdir -p "${resources_dir}"

if [[ ! -f "${source_png}" ]]; then
  if [[ "${source_png}" != "${default_png}" ]]; then
    echo "No such file: ${source_png}" >&2
    exit 1
  fi
  echo "No ${default_png}. Generating a solid-colour placeholder."
  printf '%s' "${PLACEHOLDER_PNG_BASE64}" | base64 -D >"${default_png}"
  sips -z 1024 1024 "${default_png}" --out "${default_png}" >/dev/null
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
iconset="${work}/AppIcon.iconset"
mkdir -p "${iconset}"

for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  points="${spec%%:*}"
  scale="${spec##*:}"
  pixels=$((points * scale))
  if [[ "${scale}" == "1" ]]; then
    name="icon_${points}x${points}.png"
  else
    name="icon_${points}x${points}@${scale}x.png"
  fi
  sips -z "${pixels}" "${pixels}" "${source_png}" --out "${iconset}/${name}" >/dev/null
done

iconutil --convert icns --output "${icns}" "${iconset}"

echo "Wrote ${icns} from ${source_png}"
