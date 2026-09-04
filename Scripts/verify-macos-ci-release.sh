#!/bin/bash

set -euo pipefail

readonly script_name="$(basename "$0")"
readonly script_dir="$(cd "$(dirname "$0")" && pwd -P)"

fail() {
  echo "${script_name}: $*" >&2
  exit 1
}

if [[ "$#" -ne 2 ]]; then
  fail "usage: ${script_name} <Founder's Office.app> <release-build-settings.txt>"
fi

readonly app_bundle="$1"
readonly build_settings="$2"
readonly info_plist="${app_bundle}/Contents/Info.plist"
readonly assets_car="${app_bundle}/Contents/Resources/Assets.car"
readonly privacy_manifest="${app_bundle}/Contents/Resources/PrivacyInfo.xcprivacy"

[[ -d "${app_bundle}" && ! -L "${app_bundle}" ]] || fail "missing regular app bundle: ${app_bundle}"
[[ -f "${build_settings}" && ! -L "${build_settings}" ]] || fail "missing regular build-settings file: ${build_settings}"
[[ -f "${info_plist}" && ! -L "${info_plist}" ]] || fail "missing regular Info.plist: ${info_plist}"

grep -Eq \
  '^[[:space:]]*CONFIGURATION[[:space:]]*=[[:space:]]*Release[[:space:]]*$' \
  "${build_settings}" \
  || fail "resolved build settings are not Release"

grep -Eq \
  '^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS[[:space:]]*=[[:space:]]*([^[:space:]]+[[:space:]]+)*FOUNDER_OFFICE_DISTRIBUTION([[:space:]]+[^[:space:]]+)*[[:space:]]*$' \
  "${build_settings}" \
  || fail "Release build is missing FOUNDER_OFFICE_DISTRIBUTION"

grep -Eq \
  '^[[:space:]]*ASSETCATALOG_COMPILER_APPICON_NAME[[:space:]]*=[[:space:]]*AppIcon[[:space:]]*$' \
  "${build_settings}" \
  || fail "Release build does not resolve AppIcon as its asset-catalog icon"

readonly bundle_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${info_plist}" 2>/dev/null)"
[[ "${bundle_icon_name}" == "AppIcon" ]] || fail "built app declares '${bundle_icon_name:-<missing>}' instead of AppIcon"

[[ -f "${assets_car}" && ! -L "${assets_car}" && -s "${assets_car}" ]] \
  || fail "built app is missing a non-empty compiled Assets.car"
"${script_dir}/verify-privacy-manifest.py" "${privacy_manifest}"

readonly executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null)"
[[ -n "${executable_name}" && "${executable_name}" != */* && "${executable_name}" != "." && "${executable_name}" != ".." ]] \
  || fail "built app has an unsafe or missing CFBundleExecutable"

readonly executable="${app_bundle}/Contents/MacOS/${executable_name}"
[[ -f "${executable}" && ! -L "${executable}" && -x "${executable}" ]] \
  || fail "missing regular executable: ${executable}"

"${script_dir}/verify-customer-binary-policy.sh" "${executable}"

echo "Verified unsigned macOS customer Release: assets, privacy policy, and customer binary policy passed."
