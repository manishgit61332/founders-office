#!/bin/zsh

set -euo pipefail
umask 077

script_dir="${0:A:h}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/founders-office-release-tests.XXXXXX")"
cleanup() {
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT INT TERM

assert_refused() {
    local expected="$1"
    shift
    local output
    local exit_code
    set +e
    output="$("$@" 2>&1)"
    exit_code=$?
    set -e
    (( exit_code != 0 )) || {
        print -u2 "Expected command to fail: $*"
        exit 1
    }
    [[ "$output" == *"$expected"* ]] || {
        print -u2 "Failure did not contain expected text: ${expected}"
        print -u2 -- "$output"
        exit 1
    }
}

assert_refused \
    "exactly three numeric components" \
    "$script_dir/release-macos.sh" --version 1.2.3-beta.1 --build 1

release_environment=(
    FOUNDER_OFFICE_TEAM_ID=ABCDE12345
    FOUNDER_OFFICE_BUNDLE_ID=com.example.foundersoffice
    FOUNDER_OFFICE_ICLOUD_CONTAINER=iCloud.com.example.foundersoffice
    "FOUNDER_OFFICE_DEVELOPER_ID_APPLICATION=Developer ID Application: Example (ABCDE12345)"
    FOUNDER_OFFICE_PROVISIONING_PROFILE_SPECIFIER=ExampleProfile
    FOUNDER_OFFICE_NOTARY_PROFILE=example-notary
    FOUNDER_OFFICE_UPDATE_CHANNEL=beta
    FOUNDER_OFFICE_UPDATE_PUBLIC_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
    FOUNDER_OFFICE_SUPABASE_URL=https://example-project.supabase.co
    FOUNDER_OFFICE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_12345678901234567890
    FOUNDER_OFFICE_AUTH_CALLBACK_SCHEME=founders-office
)
assert_refused \
    "exact credential-free HTTPS URL" \
    env "${release_environment[@]}" \
        "FOUNDER_OFFICE_UPDATE_FEED_URL=https://downloads.example.com/channel/beta.json?mutable=1" \
        "$script_dir/release-macos.sh" --version 1.2.3 --build 4
assert_refused \
    "public key is malformed" \
    env "${release_environment[@]}" \
        FOUNDER_OFFICE_UPDATE_PUBLIC_KEY=not-a-key \
        FOUNDER_OFFICE_UPDATE_FEED_URL=https://downloads.example.com/channel/beta.json \
        "$script_dir/release-macos.sh" --version 1.2.3 --build 4
assert_refused \
    "URL is malformed" \
    env "${release_environment[@]}" \
        FOUNDER_OFFICE_UPDATE_FEED_URL=https://downloads.example.com:70000/channel/beta.json \
        "$script_dir/release-macos.sh" --version 1.2.3 --build 4
assert_refused \
    "public client key is malformed or unsafe" \
    env "${release_environment[@]}" \
        FOUNDER_OFFICE_SUPABASE_PUBLISHABLE_KEY=sb_secret_never_embed_this_value \
        FOUNDER_OFFICE_UPDATE_FEED_URL=https://downloads.example.com/channel/beta.json \
        "$script_dir/release-macos.sh" --version 1.2.3 --build 4
assert_refused \
    "reviewed founders-office callback scheme" \
    env "${release_environment[@]}" \
        FOUNDER_OFFICE_AUTH_CALLBACK_SCHEME=founders-office-dev \
        FOUNDER_OFFICE_UPDATE_FEED_URL=https://downloads.example.com/channel/beta.json \
        "$script_dir/release-macos.sh" --version 1.2.3 --build 4

create_binary_fixture() {
    local mode="$1"
    local directory="${fixture_root}/binary-${mode}"
    mkdir -p "$directory"
    python3 - "${directory}/fixture.c" "$mode" <<'PY'
import sys
from pathlib import Path

path, mode = sys.argv[1:]
sentinels = {
    "clean": "customer-release",
    "codex": "/opt/homebrew/bin/codex",
    "codex-runner-type": "CodexRunner",
    "codex-state-type": "CodexRunState",
    "codex-action-type": "CodexTaskAction",
    "codex-footer-type": "CodexRunFooter",
    "codex-working-copy": "Codex is working on",
    "codex-prepare-copy": "Prepare with Codex",
    "codex-available-callback": "isCodexAvailable",
    "codex-run-callback": "onRunWithCodex",
}
value = sentinels[mode]
Path(path).write_text(
    f'const char *volatile sentinel = "{value}"; int main(void) {{ return sentinel[0] == 0; }}\n',
    encoding="utf-8",
)
PY
    xcrun clang -arch arm64 "${directory}/fixture.c" -o "${directory}/fixture"
}

create_swift_binary_fixture() {
    local mode="$1"
    local directory="${fixture_root}/binary-${mode}"
    mkdir -p "$directory"
    python3 - "${directory}/fixture.swift" "$mode" <<'PY'
import sys
from pathlib import Path

path, mode = sys.argv[1:]
sources = {
    "workspace": '''
import Foundation
@inline(never) func selectedRoot() -> String? {
    ProcessInfo.processInfo.environment["OPENLOOPS_ROOT"]
}
print(selectedRoot() ?? "")
''',
    "preview": '''
import Foundation
@inline(never) func isSnapshot() -> Bool {
    CommandLine.arguments.contains("--snapshot")
}
print(isSnapshot())
''',
}
Path(path).write_text(sources[mode], encoding="utf-8")
PY
    xcrun swiftc -O -target arm64-apple-macosx14.0 \
        "${directory}/fixture.swift" -o "${directory}/fixture"
}

create_binary_fixture clean
"$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-clean/fixture" arm64
assert_refused \
    "duplicate expected customer architecture" \
    "$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-clean/fixture" "arm64 arm64"

create_binary_fixture codex
assert_refused \
    "/opt/homebrew/bin/codex" \
    "$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-codex/fixture" arm64

for fixture in \
    "codex-runner-type:CodexRunner" \
    "codex-state-type:CodexRunState" \
    "codex-action-type:CodexTaskAction" \
    "codex-footer-type:CodexRunFooter" \
    "codex-working-copy:Codex is working on" \
    "codex-prepare-copy:Prepare with Codex" \
    "codex-available-callback:isCodexAvailable" \
    "codex-run-callback:onRunWithCodex"
do
    mode="${fixture%%:*}"
    sentinel="${fixture#*:}"
    create_binary_fixture "$mode"
    assert_refused \
        "$sentinel" \
        "$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-${mode}/fixture" arm64
done

create_swift_binary_fixture workspace
assert_refused \
    "OPENLOOPS_ROOT" \
    "$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-workspace/fixture" arm64

create_swift_binary_fixture preview
assert_refused \
    "--snapshot" \
    "$script_dir/verify-customer-binary-policy.sh" "${fixture_root}/binary-preview/fixture" arm64

create_privacy_fixture() {
    local mode="$1"
    local output="${fixture_root}/privacy-${mode}.xcprivacy"
    python3 - "${script_dir:h}/Apps/macOS/PrivacyInfo.xcprivacy" "$output" "$mode" <<'PY'
import plistlib
import sys

source, output, mode = sys.argv[1:]
with open(source, "rb") as handle:
    manifest = plistlib.load(handle)

if mode == "tracking":
    manifest["NSPrivacyTracking"] = True
elif mode == "collection":
    manifest["NSPrivacyCollectedDataTypes"] = [
        {
            "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeLinked": False,
            "NSPrivacyCollectedDataTypeTracking": False,
            "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
        }
    ]
elif mode == "reason":
    manifest["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] = ["INVALID.1"]
elif mode == "unexpected":
    manifest["UnreviewedPrivacyClaim"] = True
else:
    raise SystemExit(f"unknown privacy fixture mode: {mode}")

with open(output, "wb") as handle:
    plistlib.dump(manifest, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY
}

"$script_dir/verify-privacy-manifest.py" "${script_dir:h}/Apps/macOS/PrivacyInfo.xcprivacy"
ln -s "${script_dir:h}/Apps/macOS/PrivacyInfo.xcprivacy" "${fixture_root}/privacy-symlink.xcprivacy"
assert_refused \
    "regular non-symlink file" \
    "$script_dir/verify-privacy-manifest.py" "${fixture_root}/privacy-symlink.xcprivacy"

create_privacy_fixture tracking
assert_refused \
    "explicitly disable tracking" \
    "$script_dir/verify-privacy-manifest.py" "${fixture_root}/privacy-tracking.xcprivacy"

create_privacy_fixture collection
assert_refused \
    "collected data differs" \
    "$script_dir/verify-privacy-manifest.py" "${fixture_root}/privacy-collection.xcprivacy"

create_privacy_fixture reason
assert_refused \
    "accessed API declarations differ" \
    "$script_dir/verify-privacy-manifest.py" "${fixture_root}/privacy-reason.xcprivacy"

create_privacy_fixture unexpected
assert_refused \
    "unexpected keys" \
    "$script_dir/verify-privacy-manifest.py" "${fixture_root}/privacy-unexpected.xcprivacy"

create_fixture() {
    local mode="$1"
    local directory="${fixture_root}/${mode}"
    mkdir -p "$directory"
    python3 - "$directory" "$mode" <<'PY'
import hashlib
import json
import os
import stat
import sys
import uuid
import warnings
import zipfile

directory, mode = sys.argv[1:]
version = "1.2.3"
build = "4"
artifact_name = f"FoundersOffice-{version}-build-{build}-macOS.zip"
artifact_path = os.path.join(directory, artifact_name)
root = "Founder's Office.app"

with warnings.catch_warnings():
    warnings.simplefilter("ignore", UserWarning)
    with zipfile.ZipFile(artifact_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{root}/Contents/Info.plist", b"plist fixture")
        archive.writestr(f"{root}/Contents/MacOS/FoundersOffice", b"binary fixture")
        if mode == "extra-payload":
            archive.writestr("README.txt", b"unsigned payload")
        elif mode == "symlink":
            link = zipfile.ZipInfo(f"{root}/Contents/Resources/escape")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "../../outside")
        elif mode == "duplicate":
            archive.writestr(f"{root}/Contents/Info.plist", b"second plist")

with open(artifact_path, "rb") as handle:
    payload = handle.read()

manifest = {
    "schemaVersion": 1,
    "writeOnce": True,
    "createdAt": "2026-08-31T00:00:00Z",
    "product": {
        "name": "Founder's Office",
        "bundleIdentifier": "com.example.foundersoffice",
        "cloudEnabled": mode != "cloud-disabled",
        "iCloudContainer": "iCloud.com.example.foundersoffice",
        "minimumSystemVersion": "14.0",
        "architectures": ["arm64"],
    },
    "release": {
        "version": version,
        "build": build,
        "tag": f"v{version}",
        "commit": "a" * 40,
        "record": "release-record.md",
    },
    "artifact": {
        "fileName": artifact_name,
        "format": "zip",
        "sha256": hashlib.sha256(payload).hexdigest(),
        "sizeBytes": len(payload),
    },
    "signing": {
        "identity": "Developer ID Application: Example (ABCDE12345)",
        "teamIdentifier": "ABCDE12345",
        "hardenedRuntime": True,
        "timestamped": True,
    },
    "notarization": {
        "submissionId": str(uuid.UUID("00000000-0000-0000-0000-000000000001")),
        "status": "Accepted",
        "ticketStapled": True,
        "gatekeeperAssessment": "accepted",
    },
}
with open(os.path.join(directory, "release.json"), "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
with open(os.path.join(directory, "release-record.md"), "w", encoding="utf-8") as handle:
    handle.write("# Fixture release record\n")
PY
}

verify_fixture() {
    local mode="$1"
    "$script_dir/verify-macos-release.sh" \
        --artifact "${fixture_root}/${mode}/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --metadata "${fixture_root}/${mode}/release.json" \
        --expected-team-id ABCDE12345 \
        --expected-bundle-id com.example.foundersoffice \
        --expected-icloud-container iCloud.com.example.foundersoffice \
        --expected-update-feed-url https://downloads.example.com/channel/beta.json \
        --expected-update-channel beta \
        --expected-update-public-key MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY= \
        --expected-archs arm64
}

create_fixture cloud-disabled
assert_refused "does not require CloudKit" verify_fixture cloud-disabled

create_fixture extra-payload
assert_refused "outside the app bundle" verify_fixture extra-payload

create_fixture symlink
assert_refused "links and special files are forbidden" verify_fixture symlink

create_fixture duplicate
assert_refused "duplicate or colliding archive member" verify_fixture duplicate

create_fixture clean
clean_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
clean_url="https://downloads.example.com/releases/macos/v1.2.3/build-4/${clean_commit}/FoundersOffice-1.2.3-build-4-macOS.zip"
clean_manifest_url="https://downloads.example.com/releases/macos/v1.2.3/build-4/${clean_commit}/release.json"
clean_acceptance_url="https://downloads.example.com/releases/macos/v1.2.3/build-4/${clean_commit}/clean-mac-acceptance.json"
clean_acceptance="${fixture_root}/clean/clean-mac-acceptance.json"
clean_acceptance_passes=(
    immutablePublicOriginDownload
    independentReleaseVerification
    cleanInstall
    gatekeeperLaunch
    onboarding
    calendarPermissionRetention
    launchAtLoginRestart
    signedUpgradeDataRetention
    workspaceExport
    workspaceErase
    recovery
    stagedUpdate
    pausedUpdate
    correctiveRollbackEvidence
)
clean_acceptance_arguments=()
for clean_check in "${clean_acceptance_passes[@]}"; do
    clean_acceptance_arguments+=(--passed "$clean_check")
done

assert_refused \
    "required checks did not pass" \
    "$script_dir/record-macos-clean-acceptance.py" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --approved-origin https://downloads.example.com \
        --artifact-url "$clean_url" \
        --canonical-manifest-url "$clean_manifest_url" \
        --acceptance-record-url "$clean_acceptance_url" \
        --mac-model Mac15,3 \
        --macos-version 15.6.1 \
        --acceptance-id 22222222-2222-4222-8222-222222222222 \
        --tested-at 2026-08-31T01:00:00Z \
        --confirm-clean-account \
        --confirm-no-developer-certificate \
        --confirm-no-source-checkout \
        --passed immutablePublicOriginDownload \
        --output "${fixture_root}/clean/incomplete-acceptance.json"

assert_refused \
    "acceptance record URL is not the exact immutable release path" \
    "$script_dir/record-macos-clean-acceptance.py" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --approved-origin https://downloads.example.com \
        --artifact-url "$clean_url" \
        --canonical-manifest-url "$clean_manifest_url" \
        --acceptance-record-url https://downloads.example.com/releases/macos/latest-acceptance.json \
        --mac-model Mac15,3 \
        --macos-version 15.6.1 \
        --acceptance-id 22222222-2222-4222-8222-222222222222 \
        --tested-at 2026-08-31T01:00:00Z \
        --confirm-clean-account \
        --confirm-no-developer-certificate \
        --confirm-no-source-checkout \
        "${clean_acceptance_arguments[@]}" \
        --output "${fixture_root}/clean/mutable-path-acceptance.json"

"$script_dir/record-macos-clean-acceptance.py" \
    --metadata "${fixture_root}/clean/release.json" \
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
    --approved-origin https://downloads.example.com \
    --artifact-url "$clean_url" \
    --canonical-manifest-url "$clean_manifest_url" \
    --acceptance-record-url "$clean_acceptance_url" \
    --mac-model Mac15,3 \
    --macos-version 15.6.1 \
    --acceptance-id 22222222-2222-4222-8222-222222222222 \
    --tested-at 2026-08-31T01:00:00Z \
    --confirm-clean-account \
    --confirm-no-developer-certificate \
    --confirm-no-source-checkout \
    "${clean_acceptance_arguments[@]}" \
    --output "$clean_acceptance"

clean_acceptance_base=(
    --metadata "${fixture_root}/clean/release.json"
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip"
    --approved-origin https://downloads.example.com
    --artifact-url "$clean_url"
    --canonical-manifest-url "$clean_manifest_url"
    --acceptance-record-url "$clean_acceptance_url"
    --mac-model Mac15,3
    --macos-version 15.6.1
    --acceptance-id 22222222-2222-4222-8222-222222222222
    --confirm-clean-account
    --confirm-no-developer-certificate
    --confirm-no-source-checkout
)

assert_refused \
    "write-once and already exists" \
    "$script_dir/record-macos-clean-acceptance.py" \
        "${clean_acceptance_base[@]}" \
        --tested-at 2026-08-31T01:00:00Z \
        "${clean_acceptance_arguments[@]}" \
        --output "$clean_acceptance"

for noncanonical_origin in \
    https://DOWNLOADS.example.com \
    https://downloads.example.com:443 \
    https://downloads.example.com/; do
    assert_refused \
        "canonical" \
        "$script_dir/record-macos-clean-acceptance.py" \
            "${clean_acceptance_base[@]}" \
            --approved-origin "$noncanonical_origin" \
            --tested-at 2026-08-31T01:00:00Z \
            "${clean_acceptance_arguments[@]}" \
            --output "${fixture_root}/clean/noncanonical-origin.json"
done

assert_refused \
    "cannot be in the future" \
    "$script_dir/record-macos-clean-acceptance.py" \
        "${clean_acceptance_base[@]}" \
        --tested-at 9999-01-01T00:00:00Z \
        "${clean_acceptance_arguments[@]}" \
        --output "${fixture_root}/clean/future-acceptance.json"

ln -s "${fixture_root}/clean/release.json" "${fixture_root}/clean/release-symlink.json"
assert_refused \
    "regular, non-symlink file" \
    "$script_dir/record-macos-clean-acceptance.py" \
        "${clean_acceptance_base[@]}" \
        --metadata "${fixture_root}/clean/release-symlink.json" \
        --tested-at 2026-08-31T01:00:00Z \
        "${clean_acceptance_arguments[@]}" \
        --output "${fixture_root}/clean/symlink-input-acceptance.json"

assert_refused \
    "expected update feed must be an exact credential-free HTTPS URL" \
    "$script_dir/verify-macos-release.sh" \
        --artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --metadata "${fixture_root}/clean/release.json" \
        --expected-team-id ABCDE12345 \
        --expected-bundle-id com.example.foundersoffice \
        --expected-icloud-container iCloud.com.example.foundersoffice \
        --expected-update-feed-url http://downloads.example.com/channel/beta.json \
        --expected-update-channel beta \
        --expected-update-public-key MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY= \
        --expected-archs arm64
"$script_dir/prepare-website-mac-release.py" \
    --metadata "${fixture_root}/clean/release.json" \
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
    --clean-mac-acceptance "$clean_acceptance" \
    --download-url "$clean_url" \
    --approved-origin "https://downloads.example.com" \
    --output "${fixture_root}/clean/mac-release.json"

ln -s "${fixture_root}/clean/release.json" "${fixture_root}/clean/website-output-symlink.json"
assert_refused \
    "regular, non-symlink file" \
    "$script_dir/prepare-website-mac-release.py" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --clean-mac-acceptance "$clean_acceptance" \
        --download-url "$clean_url" \
        --approved-origin "https://downloads.example.com" \
        --output "${fixture_root}/clean/website-output-symlink.json"

cp "${fixture_root}/clean/release.json" "${fixture_root}/clean/alias-release.json"
assert_refused \
    "must not replace release evidence input" \
    "$script_dir/prepare-website-mac-release.py" \
        --metadata "${fixture_root}/clean/alias-release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --clean-mac-acceptance "$clean_acceptance" \
        --download-url "$clean_url" \
        --approved-origin "https://downloads.example.com" \
        --output "${fixture_root}/clean/alias-release.json"
python3 - "${fixture_root}/clean/mac-release.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if (
    manifest.get("schemaVersion") != 2
    or not manifest.get("available")
    or not manifest.get("verifiedFromCanonicalManifest")
    or not manifest.get("cleanMacAccepted")
    or manifest.get("acceptanceAttestation") != "operator-confirmed"
    or not isinstance(manifest.get("acceptanceRecordSHA256"), str)
    or len(manifest["acceptanceRecordSHA256"]) != 64
    or not manifest.get("canonicalManifestURL", "").endswith("/release.json")
):
    raise SystemExit("generated website release manifest is not clean-Mac accepted and verified")
PY

python3 - "$clean_acceptance" "${fixture_root}/clean/failed-acceptance.json" <<'PY'
import json
import sys

source, output = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    acceptance = json.load(handle)
acceptance["checks"]["launchAtLoginRestart"] = "failed"
with open(output, "w", encoding="utf-8") as handle:
    json.dump(acceptance, handle)
PY
assert_refused \
    "clean-Mac check did not pass" \
    "$script_dir/prepare-website-mac-release.py" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --clean-mac-acceptance "${fixture_root}/clean/failed-acceptance.json" \
        --download-url "$clean_url" \
        --approved-origin "https://downloads.example.com" \
        --output "${fixture_root}/clean/failed-acceptance-release.json"

python3 - "$clean_acceptance" "${fixture_root}/clean/mismatched-acceptance.json" <<'PY'
import json
import sys

source, output = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    acceptance = json.load(handle)
acceptance["release"]["commit"] = "b" * 40
with open(output, "w", encoding="utf-8") as handle:
    json.dump(acceptance, handle)
PY
assert_refused \
    "does not match the canonical release and artifact" \
    "$script_dir/prepare-website-mac-release.py" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --clean-mac-acceptance "${fixture_root}/clean/mismatched-acceptance.json" \
        --download-url "$clean_url" \
        --approved-origin "https://downloads.example.com" \
        --output "${fixture_root}/clean/mismatched-acceptance-release.json"

assert_refused \
    "exact immutable release path" \
    "$script_dir/prepare-website-mac-release.py" \
    --metadata "${fixture_root}/clean/release.json" \
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
    --clean-mac-acceptance "$clean_acceptance" \
    --download-url "https://downloads.example.com/releases/macos/latest.zip" \
    --approved-origin "https://downloads.example.com" \
    --output "${fixture_root}/clean/rejected.json"

signed_feed="${fixture_root}/clean/beta-update.json"
test_public_key_file="${fixture_root}/clean/test-update-public-key.txt"
rollout_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fixture_private_key() {
    python3 - <<'PY'
import base64
import hashlib

# Deterministic, test-only material. It is never a production credential and
# exists only in the private temporary release fixture for this process.
raw = hashlib.sha256(b"founders-office-update-signer-test-only").digest()
print(base64.b64encode(raw).decode("ascii"))
PY
}
fixture_private_key \
    | swift run --package-path "${script_dir:h}" FounderOfficeUpdateSigner \
        --export-public-key \
        --stdin-key \
        --public-key-output "$test_public_key_file"
test_public_key="$(tr -d '\n' < "$test_public_key_file")"
wrong_test_public_key="MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
set +e
wrong_key_output="$(fixture_private_key \
    | swift run --package-path "${script_dir:h}" FounderOfficeUpdateSigner \
        --stdin-key \
        --expected-public-key "$wrong_test_public_key" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --artifact-url "$clean_url" \
        --evidence-url "https://downloads.example.com/releases/macos/v1.2.3/build-4/${clean_commit}/release.json" \
        --feed-url "https://downloads.example.com/channel/beta.json" \
        --channel beta \
        --sequence 1 \
        --rollout-id 11111111-1111-1111-1111-111111111111 \
        --starts-at "$rollout_started_at" \
        --output "${fixture_root}/clean/wrong-key-update.json" 2>&1)"
wrong_key_exit=$?
set -e
(( wrong_key_exit != 0 )) || {
    print -u2 "Signer accepted a private key that did not match the reviewed public key"
    exit 1
}
[[ "$wrong_key_output" == *"private key does not match the reviewed public key"* ]] || {
    print -u2 "Signer returned the wrong finite failure for a public-key mismatch"
    exit 1
}
[[ ! -e "${fixture_root}/clean/wrong-key-update.json" ]] || {
    print -u2 "Signer created output after a public-key mismatch"
    exit 1
}
fixture_private_key \
    | swift run --package-path "${script_dir:h}" FounderOfficeUpdateSigner \
        --stdin-key \
        --expected-public-key "$test_public_key" \
        --metadata "${fixture_root}/clean/release.json" \
        --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
        --artifact-url "$clean_url" \
        --evidence-url "https://downloads.example.com/releases/macos/v1.2.3/build-4/${clean_commit}/release.json" \
        --feed-url "https://downloads.example.com/channel/beta.json" \
        --channel beta \
        --sequence 1 \
        --rollout-id 11111111-1111-1111-1111-111111111111 \
        --starts-at "$rollout_started_at" \
        --phase-count 5 \
        --phase-interval-seconds 3600 \
        --output "$signed_feed"
python3 - "$signed_feed" "$clean_url" <<'PY'
import base64
import json
import sys

path, expected_artifact_url = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    envelope = json.load(handle)
if set(envelope) != {"schemaVersion", "payload", "signature"} or envelope["schemaVersion"] != 1:
    raise SystemExit("signed update envelope schema is invalid")
signature = base64.b64decode(envelope["signature"], validate=True)
payload_bytes = base64.b64decode(envelope["payload"], validate=True)
payload = json.loads(payload_bytes)
if len(signature) != 64 or payload["release"]["artifactURL"] != expected_artifact_url:
    raise SystemExit("signed update envelope does not name the sealed artifact")
if len(payload_bytes) > 256 * 1024 or len(open(path, "rb").read()) > 512 * 1024:
    raise SystemExit("signed update envelope exceeds the runtime bounds")
PY

print "Release safety checks passed."
