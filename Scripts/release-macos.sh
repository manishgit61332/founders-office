#!/bin/zsh

set -euo pipefail
umask 077

script_dir="${0:A:h}"
project_dir="${script_dir:h}"

usage() {
    print -u2 "Usage: Scripts/release-macos.sh --version X.Y.Z --build N"
    print -u2 ""
    print -u2 "Required environment variables:"
    print -u2 "  FOUNDER_OFFICE_TEAM_ID"
    print -u2 "  FOUNDER_OFFICE_BUNDLE_ID"
    print -u2 "  FOUNDER_OFFICE_ICLOUD_CONTAINER"
    print -u2 "  FOUNDER_OFFICE_DEVELOPER_ID_APPLICATION"
    print -u2 "  FOUNDER_OFFICE_PROVISIONING_PROFILE_SPECIFIER"
    print -u2 "  FOUNDER_OFFICE_NOTARY_PROFILE"
    print -u2 "  FOUNDER_OFFICE_UPDATE_FEED_URL"
    print -u2 "  FOUNDER_OFFICE_UPDATE_CHANNEL"
    print -u2 "  FOUNDER_OFFICE_UPDATE_PUBLIC_KEY"
    print -u2 ""
    print -u2 "Release entitlements must be tracked at Config/Release/FoundersOfficeMac.entitlements."
}

fail() {
    print -u2 "Release refused: $*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

version=""
build_number=""

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { usage; exit 64; }
            version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || { usage; exit 64; }
            build_number="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            fail "unknown argument: $1"
            ;;
    esac
done

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
    || fail "--version must contain exactly three numeric components"
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] \
    || fail "--build must be a positive integer"

required_environment=(
    FOUNDER_OFFICE_TEAM_ID
    FOUNDER_OFFICE_BUNDLE_ID
    FOUNDER_OFFICE_ICLOUD_CONTAINER
    FOUNDER_OFFICE_DEVELOPER_ID_APPLICATION
    FOUNDER_OFFICE_PROVISIONING_PROFILE_SPECIFIER
    FOUNDER_OFFICE_NOTARY_PROFILE
    FOUNDER_OFFICE_UPDATE_FEED_URL
    FOUNDER_OFFICE_UPDATE_CHANNEL
    FOUNDER_OFFICE_UPDATE_PUBLIC_KEY
)

for variable_name in "${required_environment[@]}"; do
    [[ -n "${(P)variable_name:-}" ]] || fail "${variable_name} is not set"
done

team_id="$FOUNDER_OFFICE_TEAM_ID"
bundle_id="$FOUNDER_OFFICE_BUNDLE_ID"
icloud_container="$FOUNDER_OFFICE_ICLOUD_CONTAINER"
signing_identity="$FOUNDER_OFFICE_DEVELOPER_ID_APPLICATION"
provisioning_profile="$FOUNDER_OFFICE_PROVISIONING_PROFILE_SPECIFIER"
notary_profile="$FOUNDER_OFFICE_NOTARY_PROFILE"
update_feed_url="$FOUNDER_OFFICE_UPDATE_FEED_URL"
update_channel="$FOUNDER_OFFICE_UPDATE_CHANNEL"
update_public_key="$FOUNDER_OFFICE_UPDATE_PUBLIC_KEY"
required_archs="${FOUNDER_OFFICE_REQUIRED_ARCHS:-arm64 x86_64}"
release_entitlements_relative="Config/Release/FoundersOfficeMac.entitlements"
release_entitlements="${project_dir}/${release_entitlements_relative}"
privacy_policy_relative="Config/Release/PrivacyManifestPolicy.json"
required_arch_array=(${=required_archs})
(( ${#required_arch_array[@]} > 0 )) || fail "at least one release architecture is required"
seen_archs=" "
for required_arch in "${required_arch_array[@]}"; do
    [[ "$required_arch" == "arm64" || "$required_arch" == "x86_64" ]] \
        || fail "unsupported release architecture: ${required_arch}"
    [[ "$seen_archs" != *" ${required_arch} "* ]] \
        || fail "duplicate release architecture: ${required_arch}"
    seen_archs+="${required_arch} "
done

[[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || fail "FOUNDER_OFFICE_TEAM_ID is malformed"
[[ "$bundle_id" =~ '^[A-Za-z0-9][A-Za-z0-9.-]+$' ]] || fail "FOUNDER_OFFICE_BUNDLE_ID is malformed"
[[ "$icloud_container" == iCloud.* ]] || fail "FOUNDER_OFFICE_ICLOUD_CONTAINER must start with iCloud."
[[ "$signing_identity" == 'Developer ID Application:'* ]] \
    || fail "the signing identity must be a Developer ID Application identity"
[[ "$bundle_id" != "com.manish.openloops" ]] \
    || fail "the known provisional macOS bundle identifier cannot be released"
[[ "$icloud_container" != "iCloud.com.manish.foundersoffice" ]] \
    || fail "the known provisional iCloud container cannot be released"

python3 - "$update_feed_url" "$update_channel" "$update_public_key" <<'PY'
import base64
import binascii
import sys
from urllib.parse import urlsplit

feed_url, channel, public_key = sys.argv[1:]
if len(feed_url) > 2048 or any(character.isspace() for character in feed_url):
    raise SystemExit("release update feed URL is malformed")
try:
    parsed = urlsplit(feed_url)
    port = parsed.port
except ValueError:
    raise SystemExit("release update feed URL is malformed")
if (
    parsed.scheme != "https"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.query
    or parsed.fragment
    or len(parsed.path) > 1024
    or not parsed.path.startswith("/")
    or parsed.path == "/"
    or not parsed.path.endswith(".json")
    or "//" in parsed.path
    or "%" in parsed.path
    or any(component in {".", ".."} for component in parsed.path.split("/"))
    or port is not None and not 1 <= port <= 65535
):
    raise SystemExit("release update feed must be an exact credential-free HTTPS URL")
if channel not in {"beta", "stable"}:
    raise SystemExit("release update channel must be beta or stable")
if public_key != public_key.strip() or len(public_key) > 128:
    raise SystemExit("release update public key is malformed")
try:
    decoded = base64.b64decode(public_key, validate=True)
except (binascii.Error, ValueError):
    raise SystemExit("release update public key is malformed")
if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != public_key:
    raise SystemExit("release update public key must be one canonical Ed25519 public key")
PY

[[ -f "$release_entitlements" ]] || fail "release entitlements file does not exist"
[[ ! -L "$release_entitlements" ]] || fail "release entitlements file must not be a symlink"

for command_name in git python3 plutil security xcode-select xcodebuild xcodegen codesign ditto lipo shasum spctl stat; do
    require_command "$command_name"
done
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool is unavailable"
xcrun --find stapler >/dev/null 2>&1 || fail "stapler is unavailable"

developer_directory="$(xcode-select -p)"
[[ "$developer_directory" == */Xcode.app/Contents/Developer ]] \
    || fail "full Xcode must be selected; Command Line Tools alone cannot create a release"
xcodebuild -version | grep -q '^Xcode ' || fail "xcodebuild did not report a full Xcode installation"
xcodegen_version="$(xcodegen version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
[[ "$xcodegen_version" == "2.46.0" ]] \
    || fail "XcodeGen 2.46.0 is required to match CI; found ${xcodegen_version:-unknown}"

"${script_dir}/verify-privacy-manifest.py" "${project_dir}/Apps/macOS/PrivacyInfo.xcprivacy"

security find-identity -v -p codesigning \
    | grep -F -- "\"${signing_identity}\"" >/dev/null \
    || fail "the requested Developer ID Application identity is not in the active keychain"

python3 - "$release_entitlements" "$icloud_container" <<'PY'
import plistlib
import sys

path, expected_container = sys.argv[1:]
with open(path, "rb") as handle:
    entitlements = plistlib.load(handle)

errors = []
allowed_keys = {
    "aps-environment",
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.security.app-sandbox",
    "com.apple.security.application-groups",
    "com.apple.security.files.user-selected.read-only",
    "com.apple.security.network.client",
    "com.apple.security.personal-information.calendars",
}
unexpected = sorted(set(entitlements) - allowed_keys)
if unexpected:
    errors.append("unexpected entitlement keys: " + ", ".join(unexpected))
if any("temporary-exception" in key for key in entitlements):
    errors.append("temporary exception entitlements are forbidden")
for forbidden in (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
):
    if forbidden in entitlements:
        errors.append(f"forbidden release entitlement is present: {forbidden}")
if entitlements.get("com.apple.security.app-sandbox") is not True:
    errors.append("the production app must enable App Sandbox")
if entitlements.get("com.apple.security.personal-information.calendars") is not True:
    errors.append("Calendar access must be explicitly entitled")
if entitlements.get("com.apple.security.files.user-selected.read-only") is not True:
    errors.append("read-only access to user-selected files must be explicitly entitled")
if entitlements.get("aps-environment") != "production":
    errors.append("aps-environment must be production")
if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
    errors.append("the iCloud container environment must be Production")
if "CloudKit" not in entitlements.get("com.apple.developer.icloud-services", []):
    errors.append("CloudKit must be present in the iCloud services entitlement")
if entitlements.get("com.apple.developer.icloud-container-identifiers") != [expected_container]:
    errors.append("the production app must declare exactly the expected iCloud container")
if entitlements.get("com.apple.developer.icloud-services") != ["CloudKit"]:
    errors.append("the production app must declare exactly the CloudKit iCloud service")
if entitlements.get("com.apple.security.network.client") is not True:
    errors.append("the network client entitlement must be true")
groups = entitlements.get("com.apple.security.application-groups")
if groups is not None and (
    not isinstance(groups, list)
    or not groups
    or any(not isinstance(group, str) or not group.startswith("group.") for group in groups)
):
    errors.append("application groups must be a non-empty list of group.* identifiers")

if errors:
    raise SystemExit("Invalid release entitlements: " + "; ".join(errors))
PY

cd "$project_dir"
git ls-files --error-unmatch -- "$release_entitlements_relative" >/dev/null 2>&1 \
    || fail "release entitlements must be tracked at ${release_entitlements_relative}"
git ls-files --error-unmatch -- "$privacy_policy_relative" >/dev/null 2>&1 \
    || fail "reviewed privacy policy must be tracked at ${privacy_policy_relative}"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
    || fail "the Git worktree must be clean, including untracked files"

release_tag="v${version}"
git rev-parse --verify --quiet "refs/tags/${release_tag}^{commit}" >/dev/null \
    || fail "signed release input requires tag ${release_tag}"
git_commit="$(git rev-parse HEAD)"
tag_commit="$(git rev-parse "${release_tag}^{commit}")"
[[ "$git_commit" == "$tag_commit" ]] || fail "${release_tag} does not point to HEAD"
release_record="${project_dir}/docs/releases/v${version}-build-${build_number}.md"
[[ -f "$release_record" ]] || fail "release record is missing: ${release_record}"

release_parent="${project_dir}/dist/releases/macos"
commit_short="$(print -r -- "$git_commit" | cut -c1-12)"
release_dir="${release_parent}/${release_tag}-build-${build_number}-${commit_short}"
[[ ! -e "$release_dir" ]] || fail "write-once release directory already exists: ${release_dir}"
mkdir -p "$release_parent"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/founders-office-release.XXXXXX")"
cleanup() {
    if [[ -n "${work_root:-}" && -d "$work_root" ]]; then
        rm -rf -- "$work_root"
    fi
}
trap cleanup EXIT INT TERM

generated_project_root="${work_root}/project"
archive_path="${work_root}/FoundersOffice.xcarchive"
export_path="${work_root}/export"
export_options="${work_root}/ExportOptions.plist"
release_info_plist="${work_root}/Release-Info.plist"
submission_archive="${work_root}/notarization-submission.zip"
payload_dir="${work_root}/payload"
mkdir -p "$generated_project_root" "$export_path" "$payload_dir"

cp "${project_dir}/Apps/macOS/Info.plist" "$release_info_plist"
plutil -replace CFBundleShortVersionString -string "$version" "$release_info_plist"
plutil -replace CFBundleVersion -string "$build_number" "$release_info_plist"
plutil -replace FounderOfficeDistributionChannel -string "direct" "$release_info_plist" 2>/dev/null \
    || plutil -insert FounderOfficeDistributionChannel -string "direct" "$release_info_plist"
plutil -replace FounderOfficeNotarized -bool true "$release_info_plist" 2>/dev/null \
    || plutil -insert FounderOfficeNotarized -bool true "$release_info_plist"
plutil -replace FounderOfficeCloudContainerIdentifier -string "$icloud_container" "$release_info_plist" 2>/dev/null \
    || plutil -insert FounderOfficeCloudContainerIdentifier -string "$icloud_container" "$release_info_plist"
plutil -replace FounderOfficeUpdateFeedURL -string "$update_feed_url" "$release_info_plist"
plutil -replace FounderOfficeUpdateChannel -string "$update_channel" "$release_info_plist"
plutil -replace FounderOfficeUpdatePublicKey -string "$update_public_key" "$release_info_plist"
plutil -lint "$release_info_plist" >/dev/null

xcodegen generate \
    --spec "${project_dir}/project.yml" \
    --project "$generated_project_root" \
    --project-root "$project_dir"
generated_project="${generated_project_root}/FoundersOffice.xcodeproj"
[[ -d "$generated_project" ]] || fail "XcodeGen did not create FoundersOffice.xcodeproj"

xcodebuild \
    -project "$generated_project" \
    -scheme FoundersOfficeMac \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    clean archive \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    INFOPLIST_FILE="$release_info_plist" \
    GENERATE_INFOPLIST_FILE=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    PROVISIONING_PROFILE_SPECIFIER="$provisioning_profile" \
    CODE_SIGN_ENTITLEMENTS="$release_entitlements" \
    ARCHS="$required_archs" \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES

python3 - "$export_options" "$team_id" "$bundle_id" "$signing_identity" "$provisioning_profile" <<'PY'
import plistlib
import sys

path, team_id, bundle_id, identity, profile = sys.argv[1:]
options = {
    "destination": "export",
    "method": "developer-id",
    "provisioningProfiles": {bundle_id: profile},
    "signingCertificate": identity,
    "signingStyle": "manual",
    "stripSwiftSymbols": True,
    "teamID": team_id,
}
with open(path, "wb") as handle:
    plistlib.dump(options, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY

xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options"

exported_apps=("$export_path"/*.app(N))
(( ${#exported_apps[@]} == 1 )) || fail "the archive export must contain exactly one app"
app_path="${exported_apps[1]}"
info_plist="${app_path}/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "the exported app has no Info.plist"

actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
actual_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
minimum_system_version="$(plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")"
[[ "$actual_bundle_id" == "$bundle_id" ]] || fail "exported bundle identifier does not match"
[[ "$actual_version" == "$version" ]] || fail "exported version does not match"
[[ "$actual_build" == "$build_number" ]] || fail "exported build number does not match"
if plutil -extract OpenLoopsWorkspace raw -o - "$info_plist" >/dev/null 2>&1; then
    fail "the exported app contains a developer workspace path"
fi

cloud_enabled="$(plutil -extract FounderOfficeCloudEnabled raw -o - "$info_plist")"
[[ "$cloud_enabled" == "true" ]] || fail "CloudKit is not enabled in the exported app"
runtime_cloud_container="$(plutil -extract FounderOfficeCloudContainerIdentifier raw -o - "$info_plist")"
[[ "$runtime_cloud_container" == "$icloud_container" ]] \
    || fail "runtime CloudKit container does not match the release entitlement"
runtime_update_feed="$(plutil -extract FounderOfficeUpdateFeedURL raw -o - "$info_plist")"
runtime_update_channel="$(plutil -extract FounderOfficeUpdateChannel raw -o - "$info_plist")"
runtime_update_public_key="$(plutil -extract FounderOfficeUpdatePublicKey raw -o - "$info_plist")"
[[ "$runtime_update_feed" == "$update_feed_url" ]] \
    || fail "runtime update feed does not match the reviewed release setting"
[[ "$runtime_update_channel" == "$update_channel" ]] \
    || fail "runtime update channel does not match the reviewed release setting"
[[ "$runtime_update_public_key" == "$update_public_key" ]] \
    || fail "runtime update public key does not match the reviewed release setting"
distribution_channel="$(plutil -extract FounderOfficeDistributionChannel raw -o - "$info_plist")"
notarization_claim="$(plutil -extract FounderOfficeNotarized raw -o - "$info_plist")"
[[ "$distribution_channel" == "direct" ]] || fail "exported app is not marked for direct distribution"
[[ "$notarization_claim" == "true" ]] || fail "exported app is missing the notarization release marker"
privacy_manifest="${app_path}/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$privacy_manifest" ]] || fail "the privacy manifest is missing"
"${script_dir}/verify-privacy-manifest.py" "$privacy_manifest"

bundle_icon_file="$(plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null || true)"
bundle_icon_name="$(plutil -extract CFBundleIconName raw -o - "$info_plist" 2>/dev/null || true)"
if [[ -n "$bundle_icon_file" ]]; then
    icon_path="${app_path}/Contents/Resources/${bundle_icon_file}"
    if [[ ! -f "$icon_path" && "$bundle_icon_file" != *.icns ]]; then
        icon_path="${icon_path}.icns"
    fi
    [[ -f "$icon_path" ]] || fail "the macOS app icon declared by Info.plist is missing"
elif [[ -n "$bundle_icon_name" ]]; then
    [[ -f "${app_path}/Contents/Resources/Assets.car" ]] \
        || fail "the app icon asset catalog is missing"
else
    fail "the exported app has no macOS app icon declaration"
fi

executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist")"
executable_path="${app_path}/Contents/MacOS/${executable_name}"
[[ -f "$executable_path" ]] || fail "the exported executable is missing"
actual_archs="$(lipo -archs "$executable_path")"
actual_arch_array=(${=actual_archs})
actual_arch_sorted="${(j: :)${(on)actual_arch_array}}"
required_arch_sorted="${(j: :)${(on)required_arch_array}}"
[[ "$actual_arch_sorted" == "$required_arch_sorted" ]] \
    || fail "the exported app architectures do not exactly match release policy"
"${script_dir}/verify-customer-binary-policy.sh" "$executable_path" "$required_archs"

codesign_evidence="${payload_dir}/code-signature.txt"
codesign --verify --deep --strict --verbose=2 --all-architectures "$app_path"
: >"$codesign_evidence"
for required_arch in "${required_arch_array[@]}"; do
    codesign --verify --deep --strict --verbose=2 --architecture "$required_arch" "$app_path"
    architecture_signature="$(codesign -d --architecture "$required_arch" --verbose=4 "$app_path" 2>&1)"
    {
        print -r -- "Architecture: ${required_arch}"
        print -r -- "$architecture_signature"
    } >>"$codesign_evidence"
    print -r -- "$architecture_signature" | grep -F "Authority=${signing_identity}" >/dev/null \
        || fail "the ${required_arch} slice is not signed by the requested Developer ID identity"
    print -r -- "$architecture_signature" | grep -F "TeamIdentifier=${team_id}" >/dev/null \
        || fail "the ${required_arch} slice Team ID does not match"
    print -r -- "$architecture_signature" | grep -Eq 'flags=.*runtime' \
        || fail "the ${required_arch} slice is missing hardened runtime"
    print -r -- "$architecture_signature" | grep -F 'Timestamp=' >/dev/null \
        || fail "the ${required_arch} slice has no trusted timestamp"

    effective_entitlements="${payload_dir}/effective-entitlements-${required_arch}.plist"
    codesign -d --architecture "$required_arch" --entitlements :- "$app_path" \
        >"$effective_entitlements" 2>"${work_root}/entitlements-${required_arch}.log"
    plutil -lint "$effective_entitlements" >/dev/null
    python3 - "$effective_entitlements" "$team_id" "$bundle_id" "$icloud_container" <<'PY'
import plistlib
import sys

path, team_id, bundle_id, expected_container = sys.argv[1:]
with open(path, "rb") as handle:
    entitlements = plistlib.load(handle)

errors = []
if any("temporary-exception" in key for key in entitlements):
    errors.append("effective temporary exception entitlements are forbidden")
for forbidden in (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
):
    if forbidden in entitlements:
        errors.append(f"forbidden effective entitlement is present: {forbidden}")
if entitlements.get("com.apple.security.app-sandbox") is not True:
    errors.append("effective App Sandbox entitlement is missing")
if entitlements.get("com.apple.security.personal-information.calendars") is not True:
    errors.append("effective Calendar entitlement is missing")
if entitlements.get("com.apple.security.files.user-selected.read-only") is not True:
    errors.append("effective user-selected read-only file entitlement is missing")
if entitlements.get("com.apple.security.network.client") is not True:
    errors.append("effective network client entitlement is missing")
if entitlements.get("com.apple.developer.team-identifier") not in (None, team_id):
    errors.append("team identifier does not match")
if entitlements.get("com.apple.application-identifier") not in (None, f"{team_id}.{bundle_id}"):
    errors.append("application identifier does not match")
if entitlements.get("aps-environment") != "production":
    errors.append("effective push environment is not production")
if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
    errors.append("effective iCloud environment is not Production")
if entitlements.get("com.apple.developer.icloud-container-identifiers") != [expected_container]:
    errors.append("effective iCloud container does not match exactly")
if entitlements.get("com.apple.developer.icloud-services") != ["CloudKit"]:
    errors.append("effective iCloud services do not match exactly")

if errors:
    raise SystemExit("Invalid effective entitlements: " + "; ".join(errors))
PY
done

ditto -c -k --keepParent --sequesterRsrc "$app_path" "$submission_archive"
notarization_evidence="${payload_dir}/notarization-response.json"
preserve_notarization_failure() {
    local failure_parent="${project_dir}/dist/release-failures/macos"
    local failure_stamp="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    local failure_dir="${failure_parent}/${release_tag}-build-${build_number}-${failure_stamp}"
    mkdir -p "$failure_dir"
    if [[ -f "$notarization_evidence" ]]; then
        cp "$notarization_evidence" "${failure_dir}/notarization-response.json"
        chmod 0444 "${failure_dir}/notarization-response.json"
    fi
    print -u2 "Notarization evidence preserved outside the publishable release path: ${failure_dir}"
}

if ! xcrun notarytool submit "$submission_archive" \
    --keychain-profile "$notary_profile" \
    --wait \
    --output-format json >"$notarization_evidence"; then
    preserve_notarization_failure
    fail "notarytool did not complete the submission"
fi

notarization_values=("${(@f)$(python3 - "$notarization_evidence" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    response = json.load(handle)
print(response.get("status", ""))
print(response.get("id", ""))
PY
)}")
notarization_status="${notarization_values[1]:-}"
notarization_id="${notarization_values[2]:-}"
if [[ "$notarization_status" != "Accepted" ]]; then
    preserve_notarization_failure
    fail "Apple did not accept the notarization submission"
fi
if [[ -z "$notarization_id" ]]; then
    preserve_notarization_failure
    fail "the notarization response has no submission ID"
fi

xcrun stapler staple -v "$app_path"
xcrun stapler validate -v "$app_path"
codesign --verify --deep --strict --verbose=2 --all-architectures "$app_path"

gatekeeper_evidence="${payload_dir}/gatekeeper.txt"
spctl --assess --type execute --verbose=4 "$app_path" >"$gatekeeper_evidence" 2>&1 \
    || fail "Gatekeeper rejected the stapled app"
grep -F 'source=Notarized Developer ID' "$gatekeeper_evidence" >/dev/null \
    || fail "Gatekeeper did not report a notarized Developer ID source"

artifact_name="FoundersOffice-${version}-build-${build_number}-macOS.zip"
artifact_path="${payload_dir}/${artifact_name}"
# The public archive intentionally contains only one top-level app bundle.
# AppleDouble sidecars from --sequesterRsrc would violate that contract.
ditto -c -k --keepParent "$app_path" "$artifact_path"
artifact_sha256="$(shasum -a 256 "$artifact_path" | awk '{print $1}')"
artifact_size="$(stat -f '%z' "$artifact_path")"
checksum_path="${payload_dir}/${artifact_name}.sha256"
print -r -- "${artifact_sha256}  ${artifact_name}" >"$checksum_path"
cp "$release_record" "${payload_dir}/release-record.md"

manifest_path="${payload_dir}/release.json"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
python3 - \
    "$manifest_path" \
    "$version" \
    "$build_number" \
    "$release_tag" \
    "$git_commit" \
    "$bundle_id" \
    "$minimum_system_version" \
    "$actual_archs" \
    "$artifact_name" \
    "$artifact_sha256" \
    "$artifact_size" \
    "$signing_identity" \
    "$team_id" \
    "$icloud_container" \
    "$notarization_id" \
    "$notarization_status" \
    "$created_at" <<'PY'
import json
import sys

(
    path,
    version,
    build,
    tag,
    commit,
    bundle_id,
    minimum_system_version,
    architectures,
    artifact_name,
    artifact_sha256,
    artifact_size,
    signing_identity,
    team_id,
    icloud_container,
    notarization_id,
    notarization_status,
    created_at,
) = sys.argv[1:]

manifest = {
    "schemaVersion": 1,
    "writeOnce": True,
    "createdAt": created_at,
    "product": {
        "name": "Founder's Office",
        "bundleIdentifier": bundle_id,
        "cloudEnabled": True,
        "iCloudContainer": icloud_container,
        "minimumSystemVersion": minimum_system_version,
        "architectures": architectures.split(),
    },
    "release": {
        "version": version,
        "build": build,
        "tag": tag,
        "commit": commit,
        "record": "release-record.md",
    },
    "artifact": {
        "fileName": artifact_name,
        "format": "zip",
        "sha256": artifact_sha256,
        "sizeBytes": int(artifact_size),
    },
    "signing": {
        "identity": signing_identity,
        "teamIdentifier": team_id,
        "hardenedRuntime": True,
        "timestamped": True,
    },
    "notarization": {
        "submissionId": notarization_id,
        "status": notarization_status,
        "ticketStapled": True,
        "gatekeeperAssessment": "accepted",
    },
}

with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

"${script_dir}/verify-macos-release.sh" \
    --artifact "$artifact_path" \
    --metadata "$manifest_path" \
    --expected-team-id "$team_id" \
    --expected-bundle-id "$bundle_id" \
    --expected-icloud-container "$icloud_container" \
    --expected-update-feed-url "$update_feed_url" \
    --expected-update-channel "$update_channel" \
    --expected-update-public-key "$update_public_key" \
    --expected-archs "$required_archs"

chmod 0444 "$payload_dir"/*
chmod 0555 "$payload_dir"
mv "$payload_dir" "$release_dir"

print "Release verified and sealed: ${release_dir}"
print "Publish only ${release_dir}/${artifact_name} with release.json and the checksum file."
