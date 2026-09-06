#!/usr/bin/env bash
# Assembles, signs, and optionally notarizes "dist/Reolink Viewer.app".
# See docs/adr/0003-build-without-xcode.md and docs/adr/0007-unsandboxed-developer-id-app.md.
set -euo pipefail

APP_NAME="Reolink Viewer"
EXECUTABLE="reolink-viewer"
ARCHIVE_PREFIX="ReolinkViewer"
DEFAULT_KEYCHAIN_PROFILE="reolink-viewer-notary"
VLCKIT_INSTALL_NAME="@rpath/VLCKit.framework/Versions/A/VLCKit"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"
app="${dist_dir}/${APP_NAME}.app"
framework_src="${repo_root}/Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
info_plist_template="${repo_root}/Resources/Info.plist"
icns_src="${repo_root}/Resources/AppIcon.icns"

configuration="release"
identity=""
keychain_profile="${DEFAULT_KEYCHAIN_PROFILE}"
version=""
build_number=""
do_notarize=0
do_verify=0
do_archive=0
adhoc=0

usage() {
  cat <<EOF
Usage: scripts/build-app.sh [options]

  --debug                  Build the debug configuration instead of release.
  --verify                 Run codesign and spctl checks on the finished bundle.
  --archive                Write dist/${ARCHIVE_PREFIX}-<version>.zip.
  --notarize               Submit to Apple, wait, staple, then archive.
  --keychain-profile NAME  notarytool profile (default ${DEFAULT_KEYCHAIN_PROFILE}).
  --identity NAME          Signing identity (default: the first Developer ID
                           Application identity in the keychain).
  --adhoc                  Sign ad-hoc. Local smoke tests only, never a release.
  --version X.Y.Z          CFBundleShortVersionString and the archive name.
  --build N                CFBundleVersion. Sparkle needs this to increase.
  -h, --help               This text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration="debug"; shift ;;
    --verify) do_verify=1; shift ;;
    --archive) do_archive=1; shift ;;
    --notarize) do_notarize=1; shift ;;
    --adhoc) adhoc=1; shift ;;
    --keychain-profile) keychain_profile="${2:?--keychain-profile needs a name}"; shift 2 ;;
    --identity) identity="${2:?--identity needs a name}"; shift 2 ;;
    --version) version="${2:?--version needs a value}"; shift 2 ;;
    --build) build_number="${2:?--build needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${adhoc} -eq 1 && ${do_notarize} -eq 1 ]]; then
  echo "--adhoc cannot be notarized. Apple accepts Developer ID signatures only." >&2
  exit 2
fi

# --- inputs -----------------------------------------------------------------

if [[ ! -d "${framework_src}" ]]; then
  echo "No VLCKit at ${framework_src}. Run scripts/fetch-vlckit.sh first." >&2
  exit 1
fi

if [[ ! -f "${icns_src}" ]]; then
  echo "No ${icns_src}. Run scripts/make-icon.sh first." >&2
  exit 1
fi

if [[ ! -f "${info_plist_template}" ]]; then
  echo "No ${info_plist_template}." >&2
  exit 1
fi

if [[ -z "${version}" ]]; then
  if [[ -f "${repo_root}/VERSION" ]]; then
    version="$(tr -d '[:space:]' <"${repo_root}/VERSION")"
  else
    version="$(git -C "${repo_root}" describe --tags --abbrev=0 2>/dev/null || true)"
    version="${version#v}"
  fi
fi
version="${version:-0.0.0}"

if [[ -z "${build_number}" ]]; then
  build_number="$(git -C "${repo_root}" rev-list --count HEAD 2>/dev/null || true)"
fi
build_number="${build_number:-1}"

# --- signing identity -------------------------------------------------------

if [[ ${adhoc} -eq 1 ]]; then
  identity="-"
elif [[ -z "${identity}" ]]; then
  identity="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [[ -z "${identity}" ]]; then
  cat >&2 <<EOF
No "Developer ID Application" identity in the login keychain.

To install one:
  1. Join the Apple Developer Program (paid). The App Store is not a target,
     but Developer ID certificates need a paid membership.
  2. At https://developer.apple.com/account/resources/certificates create a
     certificate of type "Developer ID Application".
  3. Download it and open it, so that it joins the login keychain next to its
     private key.
  4. Install the Apple intermediate "Developer ID Certification Authority (G2)"
     from https://www.apple.com/certificateauthority/ if the certificate shows
     as untrusted.
  5. Confirm with: security find-identity -v -p codesigning

For a local smoke test that is not distributable, use --adhoc, or name another
identity with --identity.
EOF
  exit 1
fi

team_id="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"${identity}")"

# --- build ------------------------------------------------------------------

echo "Building ${EXECUTABLE} (${configuration})"
swift build --package-path "${repo_root}" -c "${configuration}"
bin_path="$(swift build --package-path "${repo_root}" -c "${configuration}" --show-bin-path)"

if [[ ! -f "${bin_path}/${EXECUTABLE}" ]]; then
  echo "No ${EXECUTABLE} at ${bin_path}." >&2
  exit 1
fi

# --- assemble ---------------------------------------------------------------

echo "Assembling ${app}"
rm -rf "${app}"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources" "${app}/Contents/Frameworks"

cp "${bin_path}/${EXECUTABLE}" "${app}/Contents/MacOS/${EXECUTABLE}"
cp "${icns_src}" "${app}/Contents/Resources/AppIcon.icns"
printf 'APPL????' >"${app}/Contents/PkgInfo"

sed -e "s/__VERSION__/${version}/g" -e "s/__BUILD__/${build_number}/g" \
  "${info_plist_template}" >"${app}/Contents/Info.plist"
plutil -lint "${app}/Contents/Info.plist" >/dev/null

# ditto keeps the Versions/Current symlink farm that makes it a valid framework.
ditto "${framework_src}" "${app}/Contents/Frameworks/VLCKit.framework"

echo "  version ${version}, build ${build_number}"

# --- link paths -------------------------------------------------------------

exe="${app}/Contents/MacOS/${EXECUTABLE}"
embedded_fw="${app}/Contents/Frameworks/VLCKit.framework"

load_paths() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

rpaths() {
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { want = 1 } want && $1 == "path" { print $2; want = 0 }'
}

if ! rpaths "${exe}" | grep -qx '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "${exe}"
fi

vlckit_load_path="$(load_paths "${exe}" | grep 'VLCKit\.framework' | head -1 || true)"

if [[ -z "${vlckit_load_path}" ]]; then
  echo "warning: ${EXECUTABLE} does not link VLCKit" >&2
elif [[ "${vlckit_load_path}" != @* ]]; then
  # An absolute path here is the Vendor/ or .build/ copy on this Mac, which
  # does not exist anywhere else.
  echo "  rewriting VLCKit install name: ${vlckit_load_path}"
  install_name_tool -change "${vlckit_load_path}" "${VLCKIT_INSTALL_NAME}" "${exe}"
  vlckit_load_path="${VLCKIT_INSTALL_NAME}"
fi

if [[ -n "${vlckit_load_path}" ]]; then
  case "${vlckit_load_path}" in
    @executable_path/*) resolved="${app}/Contents/MacOS/${vlckit_load_path#@executable_path/}" ;;
    @loader_path/*)     resolved="${app}/Contents/MacOS/${vlckit_load_path#@loader_path/}" ;;
    @rpath/*)           resolved="${app}/Contents/Frameworks/${vlckit_load_path#@rpath/}" ;;
    *)                  resolved="${vlckit_load_path}" ;;
  esac
  if [[ ! -f "${resolved}" ]]; then
    echo "error: ${vlckit_load_path} does not resolve inside the bundle" >&2
    exit 1
  fi
  echo "  VLCKit loads from ${vlckit_load_path}"
fi

# The toolchain adds a back-deployment rpath naming a local Xcode path. Every
# Swift dylib this binary loads resolves through an absolute /usr/lib/swift path,
# so the rpath is unused. Remove it rather than ship a local path.
while IFS= read -r path; do
  case "${path}" in
    *Xcode.app*|*.xctoolchain*)
      install_name_tool -delete_rpath "${path}" "${exe}"
      echo "  removed toolchain rpath ${path}"
      ;;
    @*|/usr/lib/*|/System/*) ;;
    *) echo "warning: LC_RPATH points outside the bundle: ${path}" >&2 ;;
  esac
done < <(rpaths "${exe}")

# --- sign, inside out -------------------------------------------------------
# ADR 0007. Never codesign --deep: it invents the nested signatures instead of
# using the ones this loop makes.

codesign_args=(--force --sign "${identity}")
if [[ ${adhoc} -eq 1 ]]; then
  # No hardened runtime for an ad-hoc build. Two ad-hoc signatures carry no Team
  # ID, so library validation reads them as different teams and refuses to load
  # VLCKit. A Developer ID puts the same Team ID on both sides.
  echo "Signing ad-hoc, without the hardened runtime. Not distributable."
else
  codesign_args+=(--options runtime --timestamp)
  echo "Signing with ${identity}"
fi

nested=0
while IFS= read -r -d '' target; do
  codesign "${codesign_args[@]}" "${target}"
  nested=$((nested + 1))
done < <(find "${embedded_fw}" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

while IFS= read -r -d '' target; do
  codesign "${codesign_args[@]}" "${target}"
  nested=$((nested + 1))
done < <(find "${embedded_fw}" -mindepth 1 -type d \( -name '*.framework' -o -name '*.bundle' \) -print0)

echo "  re-signed ${nested} nested binaries inside VLCKit.framework"
if [[ ${nested} -eq 0 ]]; then
  # VLCKit 3.7.3 links every VLC plugin into the framework binary. Look for the
  # _vlc_static_modules symbol. A build that ships loadable plugins instead puts
  # about a hundred dylibs under Versions/A/plugins, and the loop above signs
  # them.
  echo "  (this VLCKit build links its plugins statically, so there are none)"
fi

codesign "${codesign_args[@]}" "${embedded_fw}/Versions/A"
codesign "${codesign_args[@]}" "${app}"

# --- verify -----------------------------------------------------------------

run_verify() {
  echo "Verifying"
  codesign --verify --deep --strict --verbose=2 "${app}"
  codesign -d --entitlements :- "${app}"
  if ! spctl -a -vvv -t exec "${app}"; then
    if [[ ${do_notarize} -eq 1 ]]; then
      echo "spctl rejected a notarized app." >&2
      exit 1
    fi
    echo "spctl rejected the app. Expected until it is notarized and stapled."
  fi
}

# Verification of a notarized build has to wait until the ticket is stapled.
if [[ ${do_verify} -eq 1 && ${do_notarize} -eq 0 ]]; then
  run_verify
fi

# --- notarize ---------------------------------------------------------------

if [[ ${do_notarize} -eq 1 ]]; then
  cat <<EOF
Notarizing with keychain profile "${keychain_profile}".
Create that profile once, by hand, before the first run:

  xcrun notarytool store-credentials "${keychain_profile}" \\
    --apple-id "you@example.com" \\
    --team-id "${team_id:-YOURTEAMID}" \\
    --password "app-specific-password-from-appleid.apple.com"

EOF
  submission_zip="${dist_dir}/${ARCHIVE_PREFIX}-${version}-submission.zip"
  rm -f "${submission_zip}"
  ditto -c -k --keepParent "${app}" "${submission_zip}"
  xcrun notarytool submit "${submission_zip}" --keychain-profile "${keychain_profile}" --wait
  rm -f "${submission_zip}"

  xcrun stapler staple "${app}"
  do_archive=1
  if [[ ${do_verify} -eq 1 ]]; then
    run_verify
  fi
fi

# --- archive ----------------------------------------------------------------

if [[ ${do_archive} -eq 1 ]]; then
  # A future Sparkle appcast reads this name off a GitHub release. See CONTEXT.md.
  archive="${dist_dir}/${ARCHIVE_PREFIX}-${version}.zip"
  rm -f "${archive}"
  ditto -c -k --keepParent "${app}" "${archive}"
  echo "Wrote ${archive}"
fi

echo "Done: ${app}"
