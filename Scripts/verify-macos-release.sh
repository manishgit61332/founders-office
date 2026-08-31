#!/bin/zsh

set -euo pipefail
umask 077

script_dir="${0:A:h}"

usage() {
    print -u2 "Usage: Scripts/verify-macos-release.sh --artifact PATH.zip --metadata PATH.json --expected-team-id TEAM_ID --expected-bundle-id BUNDLE_ID --expected-icloud-container CONTAINER --expected-update-feed-url HTTPS_URL --expected-update-channel beta|stable --expected-update-public-key BASE64 --expected-archs 'arm64 x86_64'"
}

fail() {
    print -u2 "Verification failed: $*"
    exit 1
}

artifact_path=""
metadata_path=""
expected_team_id=""
expected_bundle_id=""
expected_icloud_container=""
expected_update_feed_url=""
expected_update_channel=""
expected_update_public_key=""
expected_archs=""

while (( $# > 0 )); do
    case "$1" in
        --artifact)
            (( $# >= 2 )) || { usage; exit 64; }
            artifact_path="$2"
            shift 2
            ;;
        --metadata)
            (( $# >= 2 )) || { usage; exit 64; }
            metadata_path="$2"
            shift 2
            ;;
        --expected-team-id)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_team_id="$2"
            shift 2
            ;;
        --expected-bundle-id)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_bundle_id="$2"
            shift 2
            ;;
        --expected-icloud-container)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_icloud_container="$2"
            shift 2
            ;;
        --expected-archs)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_archs="$2"
            shift 2
            ;;
        --expected-update-feed-url)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_update_feed_url="$2"
            shift 2
            ;;
        --expected-update-channel)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_update_channel="$2"
            shift 2
            ;;
        --expected-update-public-key)
            (( $# >= 2 )) || { usage; exit 64; }
            expected_update_public_key="$2"
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

[[ -f "$artifact_path" && ! -L "$artifact_path" ]] || fail "artifact must be a regular non-symlink file"
[[ -f "$metadata_path" && ! -L "$metadata_path" ]] || fail "metadata must be a regular non-symlink file"
[[ "$expected_team_id" =~ '^[A-Z0-9]{10}$' ]] || fail "expected Team ID is malformed"
[[ "$expected_bundle_id" =~ '^[A-Za-z0-9][A-Za-z0-9.-]+$' ]] || fail "expected bundle identifier is malformed"
[[ "$expected_icloud_container" == iCloud.* ]] || fail "expected iCloud container is malformed"
python3 - "$expected_update_feed_url" "$expected_update_channel" "$expected_update_public_key" <<'PY'
import base64
import binascii
import sys
from urllib.parse import urlsplit

feed_url, channel, public_key = sys.argv[1:]
try:
    parsed = urlsplit(feed_url)
    port = parsed.port
except ValueError:
    raise SystemExit("expected update feed URL is malformed")
if (
    len(feed_url) > 2048
    or any(character.isspace() for character in feed_url)
    or parsed.scheme != "https"
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
    raise SystemExit("expected update feed must be an exact credential-free HTTPS URL")
if channel not in {"beta", "stable"}:
    raise SystemExit("expected update channel must be beta or stable")
if public_key != public_key.strip() or len(public_key) > 128:
    raise SystemExit("expected update public key is malformed")
try:
    decoded = base64.b64decode(public_key, validate=True)
except (binascii.Error, ValueError):
    raise SystemExit("expected update public key is malformed")
if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != public_key:
    raise SystemExit("expected update public key must be one canonical Ed25519 public key")
PY
[[ -n "$expected_archs" ]] || fail "expected architectures are missing"
for expected_arch in ${=expected_archs}; do
    [[ "$expected_arch" == "arm64" || "$expected_arch" == "x86_64" ]] \
        || fail "unsupported expected architecture: ${expected_arch}"
done

for command_name in python3 plutil codesign ditto lipo shasum spctl stat; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is unavailable: ${command_name}"
done
(( $(stat -f '%z' "$metadata_path") <= 1048576 )) || fail "metadata exceeds the 1 MiB safety limit"
xcrun --find stapler >/dev/null 2>&1 || fail "stapler is unavailable"

metadata_values=("${(@f)$(python3 - "$metadata_path" "$artifact_path" <<'PY'
import datetime
import json
import os
import re
import sys
import uuid

metadata_path, artifact_path = sys.argv[1:]

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SystemExit(f"duplicate release metadata key: {key}")
        result[key] = value
    return result

with open(metadata_path, encoding="utf-8") as handle:
    manifest = json.load(handle, object_pairs_hook=reject_duplicate_keys)

def require_exact_keys(value, expected, label):
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be an object")
    missing = sorted(expected - set(value))
    unexpected = sorted(set(value) - expected)
    if missing or unexpected:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if unexpected:
            details.append("unexpected " + ", ".join(unexpected))
        raise SystemExit(f"invalid {label} fields: " + "; ".join(details))

require_exact_keys(
    manifest,
    {"schemaVersion", "writeOnce", "createdAt", "product", "release", "artifact", "signing", "notarization"},
    "release metadata",
)

if manifest.get("schemaVersion") != 1:
    raise SystemExit("unsupported release metadata schema")
if manifest.get("writeOnce") is not True:
    raise SystemExit("release metadata is not marked write-once")
try:
    datetime.datetime.strptime(manifest.get("createdAt", ""), "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    raise SystemExit("release metadata has an invalid UTC creation timestamp")

artifact = manifest.get("artifact", {})
require_exact_keys(artifact, {"fileName", "format", "sha256", "sizeBytes"}, "artifact")
if artifact.get("fileName") != os.path.basename(artifact_path):
    raise SystemExit("artifact filename does not match release metadata")
if artifact.get("format") != "zip":
    raise SystemExit("release artifact is not a zip")
if not re.fullmatch(r"[0-9a-f]{64}", artifact.get("sha256", "")):
    raise SystemExit("artifact SHA-256 is malformed")
if isinstance(artifact.get("sizeBytes"), bool) or not isinstance(artifact.get("sizeBytes"), int) or artifact["sizeBytes"] <= 0:
    raise SystemExit("artifact size is malformed")

product = manifest.get("product", {})
release = manifest.get("release", {})
signing = manifest.get("signing", {})
notarization = manifest.get("notarization", {})
require_exact_keys(
    product,
    {"name", "bundleIdentifier", "cloudEnabled", "iCloudContainer", "minimumSystemVersion", "architectures"},
    "product",
)
require_exact_keys(release, {"version", "build", "tag", "commit", "record"}, "release")
require_exact_keys(signing, {"identity", "teamIdentifier", "hardenedRuntime", "timestamped"}, "signing")
require_exact_keys(
    notarization,
    {"submissionId", "status", "ticketStapled", "gatekeeperAssessment"},
    "notarization",
)
if product.get("name") != "Founder's Office":
    raise SystemExit("release metadata names an unexpected product")
if product.get("cloudEnabled") is not True:
    raise SystemExit("release metadata does not require CloudKit")
if not re.fullmatch(r"[0-9]+\.[0-9]+(\.[0-9]+)?", product.get("minimumSystemVersion", "")):
    raise SystemExit("minimum system version is malformed")
architectures = product.get("architectures")
if (
    not isinstance(architectures, list)
    or not architectures
    or len(architectures) != len(set(architectures))
    or any(item not in {"arm64", "x86_64"} for item in architectures)
):
    raise SystemExit("release architectures are malformed")
version = release.get("version", "")
if not isinstance(release.get("build"), str):
    raise SystemExit("release build must be encoded as a string")
build = release.get("build", "")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("release version must contain exactly three numeric components")
if not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("release build must be a positive integer")
if release.get("tag") != f"v{version}":
    raise SystemExit("release tag does not match the version")
if not re.fullmatch(r"[0-9a-f]{40}", release.get("commit", "")):
    raise SystemExit("release commit is malformed")
if release.get("record") != "release-record.md":
    raise SystemExit("release record path is invalid")
expected_artifact_name = f"FoundersOffice-{version}-build-{build}-macOS.zip"
if artifact.get("fileName") != expected_artifact_name:
    raise SystemExit("artifact filename does not match version and build")
if not isinstance(signing.get("identity"), str) or not signing["identity"].startswith("Developer ID Application:"):
    raise SystemExit("signing identity is malformed")
if not re.fullmatch(r"[A-Z0-9]{10}", signing.get("teamIdentifier", "")):
    raise SystemExit("signing Team ID is malformed")
if signing.get("hardenedRuntime") is not True or signing.get("timestamped") is not True:
    raise SystemExit("release metadata does not require hardened, timestamped signing")
if (
    notarization.get("status") != "Accepted"
    or notarization.get("ticketStapled") is not True
    or notarization.get("gatekeeperAssessment") != "accepted"
):
    raise SystemExit("release metadata does not record accepted, stapled notarization")
try:
    uuid.UUID(notarization.get("submissionId", ""))
except (AttributeError, TypeError, ValueError):
    raise SystemExit("notarization submission ID is malformed")

values = [
    artifact.get("sha256", ""),
    str(artifact.get("sizeBytes", "")),
    product.get("bundleIdentifier", ""),
    release.get("version", ""),
    str(release.get("build", "")),
    signing.get("teamIdentifier", ""),
    " ".join(architectures),
    product.get("iCloudContainer", ""),
    product.get("minimumSystemVersion", ""),
    signing.get("identity", ""),
    notarization.get("submissionId", ""),
    release.get("tag", ""),
    release.get("commit", ""),
    release.get("record", ""),
]
if any(not value for value in values):
    raise SystemExit("release metadata is incomplete")
print("\n".join(values))
PY
)}")

expected_sha256="${metadata_values[1]:-}"
expected_size="${metadata_values[2]:-}"
metadata_bundle_id="${metadata_values[3]:-}"
expected_version="${metadata_values[4]:-}"
expected_build="${metadata_values[5]:-}"
metadata_team_id="${metadata_values[6]:-}"
metadata_archs="${metadata_values[7]:-}"
metadata_icloud_container="${metadata_values[8]:-}"
metadata_minimum_system_version="${metadata_values[9]:-}"
metadata_signing_identity="${metadata_values[10]:-}"
metadata_notarization_id="${metadata_values[11]:-}"
metadata_release_tag="${metadata_values[12]:-}"
metadata_release_commit="${metadata_values[13]:-}"
metadata_release_record="${metadata_values[14]:-}"
[[ "$metadata_bundle_id" == "$expected_bundle_id" ]] \
    || fail "release metadata does not match the independently supplied bundle identifier"
[[ "$metadata_team_id" == "$expected_team_id" ]] \
    || fail "release metadata does not match the independently supplied Team ID"
[[ "$metadata_icloud_container" == "$expected_icloud_container" ]] \
    || fail "release metadata does not match the independently supplied iCloud container"
metadata_arch_array=(${=metadata_archs})
expected_arch_array=(${=expected_archs})
metadata_arch_sorted="${(j: :)${(on)metadata_arch_array}}"
expected_arch_sorted="${(j: :)${(on)expected_arch_array}}"
[[ "$metadata_arch_sorted" == "$expected_arch_sorted" ]] \
    || fail "release metadata architectures do not exactly match independent policy"
release_record_path="${metadata_path:A:h}/${metadata_release_record}"
[[ -f "$release_record_path" && ! -L "$release_record_path" && -s "$release_record_path" ]] \
    || fail "release record is missing, empty, or a symlink"

actual_sha256="$(shasum -a 256 "$artifact_path" | awk '{print $1}')"
actual_size="$(stat -f '%z' "$artifact_path")"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail "SHA-256 does not match release metadata"
[[ "$actual_size" == "$expected_size" ]] || fail "artifact size does not match release metadata"

python3 - "$artifact_path" <<'PY'
import pathlib
import stat
import sys
import unicodedata
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    members = archive.infolist()
    if not members or len(members) > 20_000:
        raise SystemExit("archive entry count is invalid")

    roots = set()
    seen = set()
    total_uncompressed = 0
    required_info = None
    required_executable_directory = False
    for info in members:
        member = info.filename
        if not member or "\x00" in member or "\\" in member:
            raise SystemExit(f"unsafe archive member: {member!r}")
        path = pathlib.PurePosixPath(member)
        raw_parts = member.rstrip("/").split("/")
        if (
            path.is_absolute()
            or not raw_parts
            or any(part in {"", ".", ".."} for part in raw_parts)
        ):
            raise SystemExit(f"unsafe archive member: {member}")

        normalized = "/".join(unicodedata.normalize("NFC", part).casefold() for part in raw_parts)
        if normalized in seen:
            raise SystemExit(f"duplicate or colliding archive member: {member}")
        seen.add(normalized)

        root = raw_parts[0]
        if not root.endswith(".app") or root in {".app", "..app"}:
            raise SystemExit(f"archive member is outside the app bundle: {member}")
        roots.add(root)

        unix_mode = (info.external_attr >> 16) & 0xFFFF
        file_type = stat.S_IFMT(unix_mode)
        if info.is_dir():
            if file_type not in (0, stat.S_IFDIR):
                raise SystemExit(f"archive directory has an invalid file type: {member}")
        elif file_type not in (0, stat.S_IFREG):
            raise SystemExit(f"links and special files are forbidden: {member}")
        if info.flag_bits & 0x1:
            raise SystemExit(f"encrypted archive members are forbidden: {member}")
        if info.file_size > 512 * 1024 * 1024:
            raise SystemExit(f"archive member is too large: {member}")
        if info.file_size and info.compress_size == 0:
            raise SystemExit(f"archive member has an invalid compression size: {member}")
        if info.compress_size and info.file_size / info.compress_size > 1_000:
            raise SystemExit(f"archive member compression ratio is unsafe: {member}")
        total_uncompressed += info.file_size
        if total_uncompressed > 2 * 1024 * 1024 * 1024:
            raise SystemExit("archive expands beyond the verification limit")

        suffix = "/".join(raw_parts[1:])
        if suffix == "Contents/Info.plist":
            required_info = member
        if suffix.startswith("Contents/MacOS/") and not info.is_dir():
            required_executable_directory = True

    if len(roots) != 1 or required_info is None or not required_executable_directory:
        raise SystemExit("archive must contain exactly one complete top-level app bundle")
PY

verification_root="$(mktemp -d "${TMPDIR:-/tmp}/founders-office-verify.XXXXXX")"
cleanup() {
    if [[ -n "${verification_root:-}" && -d "$verification_root" ]]; then
        rm -rf -- "$verification_root"
    fi
}
trap cleanup EXIT INT TERM

ditto -x -k "$artifact_path" "$verification_root"
top_level=("$verification_root"/*(DN))
(( ${#top_level[@]} == 1 )) || fail "archive extraction produced extra top-level payloads"
app_path="${top_level[1]}"
[[ -d "$app_path" && "$app_path" == *.app ]] || fail "archive top level is not one app bundle"
python3 - "$app_path" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
for directory, names, files in os.walk(root, followlinks=False):
    for name in names + files:
        path = os.path.join(directory, name)
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SystemExit(f"extracted bundle contains a link or special file: {path}")
PY
info_plist="${app_path}/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "app Info.plist is missing"

actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
actual_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
actual_minimum_system_version="$(plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")"
[[ "$actual_bundle_id" == "$expected_bundle_id" ]] || fail "bundle identifier does not match metadata"
[[ "$actual_version" == "$expected_version" ]] || fail "version does not match metadata"
[[ "$actual_build" == "$expected_build" ]] || fail "build number does not match metadata"
[[ "$actual_minimum_system_version" == "$metadata_minimum_system_version" ]] \
    || fail "minimum system version does not match metadata"
if plutil -extract OpenLoopsWorkspace raw -o - "$info_plist" >/dev/null 2>&1; then
    fail "release contains a developer workspace path"
fi
distribution_channel="$(plutil -extract FounderOfficeDistributionChannel raw -o - "$info_plist")"
notarization_claim="$(plutil -extract FounderOfficeNotarized raw -o - "$info_plist")"
cloud_enabled="$(plutil -extract FounderOfficeCloudEnabled raw -o - "$info_plist")"
runtime_cloud_container="$(plutil -extract FounderOfficeCloudContainerIdentifier raw -o - "$info_plist")"
runtime_update_feed="$(plutil -extract FounderOfficeUpdateFeedURL raw -o - "$info_plist")"
runtime_update_channel="$(plutil -extract FounderOfficeUpdateChannel raw -o - "$info_plist")"
runtime_update_public_key="$(plutil -extract FounderOfficeUpdatePublicKey raw -o - "$info_plist")"
[[ "$distribution_channel" == "direct" ]] || fail "app is not marked for direct distribution"
[[ "$notarization_claim" == "true" ]] || fail "app is missing the notarization release marker"
[[ "$cloud_enabled" == "true" ]] || fail "app does not enable CloudKit"
[[ "$runtime_cloud_container" == "$expected_icloud_container" ]] \
    || fail "runtime CloudKit container does not match the signed release"
[[ "$runtime_update_feed" == "$expected_update_feed_url" ]] \
    || fail "runtime update feed does not match independent release policy"
[[ "$runtime_update_channel" == "$expected_update_channel" ]] \
    || fail "runtime update channel does not match independent release policy"
[[ "$runtime_update_public_key" == "$expected_update_public_key" ]] \
    || fail "runtime update public key does not match independent release policy"
privacy_manifest="${app_path}/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$privacy_manifest" ]] || fail "privacy manifest is missing"
"${script_dir}/verify-privacy-manifest.py" "$privacy_manifest"

bundle_icon_file="$(plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null || true)"
bundle_icon_name="$(plutil -extract CFBundleIconName raw -o - "$info_plist" 2>/dev/null || true)"
if [[ -n "$bundle_icon_file" ]]; then
    icon_path="${app_path}/Contents/Resources/${bundle_icon_file}"
    if [[ ! -f "$icon_path" && "$bundle_icon_file" != *.icns ]]; then
        icon_path="${icon_path}.icns"
    fi
    [[ -f "$icon_path" ]] || fail "declared macOS app icon is missing"
elif [[ -n "$bundle_icon_name" ]]; then
    [[ -f "${app_path}/Contents/Resources/Assets.car" ]] || fail "app icon asset catalog is missing"
else
    fail "app has no macOS app icon declaration"
fi

executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist")"
executable_path="${app_path}/Contents/MacOS/${executable_name}"
[[ -f "$executable_path" ]] || fail "app executable is missing"
actual_archs="$(lipo -archs "$executable_path")"
actual_arch_array=(${=actual_archs})
actual_arch_sorted="${(j: :)${(on)actual_arch_array}}"
[[ "$actual_arch_sorted" == "$expected_arch_sorted" ]] \
    || fail "app architectures do not exactly match independent policy"
"${script_dir}/verify-customer-binary-policy.sh" "$executable_path" "$expected_archs"

codesign --verify --deep --strict --verbose=2 --all-architectures "$app_path"
for expected_arch in "${expected_arch_array[@]}"; do
    codesign --verify --deep --strict --verbose=2 --architecture "$expected_arch" "$app_path"
    signature_details="$(codesign -d --architecture "$expected_arch" --verbose=4 "$app_path" 2>&1)"
    print -r -- "$signature_details" | grep -F "TeamIdentifier=${expected_team_id}" >/dev/null \
        || fail "${expected_arch} signature Team ID does not match metadata"
    print -r -- "$signature_details" | grep -F "Authority=${metadata_signing_identity}" >/dev/null \
        || fail "${expected_arch} signature authority does not match release metadata"
    print -r -- "$signature_details" | grep -Eq 'flags=.*runtime' \
        || fail "${expected_arch} hardened runtime is missing"
    print -r -- "$signature_details" | grep -F 'Timestamp=' >/dev/null \
        || fail "${expected_arch} trusted signing timestamp is missing"

    effective_entitlements="${verification_root}/effective-entitlements-${expected_arch}.plist"
    codesign -d --architecture "$expected_arch" --entitlements :- "$app_path" \
        >"$effective_entitlements" 2>"${verification_root}/entitlements-${expected_arch}.log"
    plutil -lint "$effective_entitlements" >/dev/null
    python3 - "$effective_entitlements" "$expected_team_id" "$expected_bundle_id" "$expected_icloud_container" <<'PY'
import plistlib
import sys

path, team_id, bundle_id, expected_container = sys.argv[1:]
with open(path, "rb") as handle:
    entitlements = plistlib.load(handle)

errors = []
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
    errors.append("App Sandbox entitlement is missing")
if entitlements.get("com.apple.security.personal-information.calendars") is not True:
    errors.append("Calendar entitlement is missing")
if entitlements.get("com.apple.security.files.user-selected.read-only") is not True:
    errors.append("user-selected read-only file entitlement is missing")
if entitlements.get("com.apple.security.network.client") is not True:
    errors.append("network client entitlement is missing")
if entitlements.get("com.apple.developer.team-identifier") not in (None, team_id):
    errors.append("team identifier does not match")
if entitlements.get("com.apple.application-identifier") not in (None, f"{team_id}.{bundle_id}"):
    errors.append("application identifier does not match")
if entitlements.get("aps-environment") != "production":
    errors.append("push environment is not production")
if entitlements.get("com.apple.developer.applesignin") != ["Default"]:
    errors.append("Sign in with Apple entitlement is missing or invalid")
if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
    errors.append("iCloud environment is not Production")
if entitlements.get("com.apple.developer.icloud-container-identifiers") != [expected_container]:
    errors.append("iCloud container does not match exactly")
if entitlements.get("com.apple.developer.icloud-services") != ["CloudKit"]:
    errors.append("iCloud services do not match exactly")

if errors:
    raise SystemExit("Invalid effective entitlements: " + "; ".join(errors))
PY
done

xcrun stapler validate -v "$app_path"
gatekeeper_details="$(spctl --assess --type execute --verbose=4 "$app_path" 2>&1)" \
    || fail "Gatekeeper rejected the app"
print -r -- "$gatekeeper_details" | grep -F 'source=Notarized Developer ID' >/dev/null \
    || fail "Gatekeeper did not report a notarized Developer ID source"

print "Verified macOS release: ${artifact_path}"
