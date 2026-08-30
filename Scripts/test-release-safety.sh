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
"$script_dir/prepare-website-mac-release.py" \
    --metadata "${fixture_root}/clean/release.json" \
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
    --download-url "$clean_url" \
    --approved-origin "https://downloads.example.com" \
    --output "${fixture_root}/clean/mac-release.json"
python3 - "${fixture_root}/clean/mac-release.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if not manifest.get("available") or not manifest.get("verifiedFromCanonicalManifest"):
    raise SystemExit("generated website release manifest is not enabled and verified")
PY
assert_refused \
    "exact immutable release path" \
    "$script_dir/prepare-website-mac-release.py" \
    --metadata "${fixture_root}/clean/release.json" \
    --verified-artifact "${fixture_root}/clean/FoundersOffice-1.2.3-build-4-macOS.zip" \
    --download-url "https://downloads.example.com/releases/macos/latest.zip" \
    --approved-origin "https://downloads.example.com" \
    --output "${fixture_root}/clean/rejected.json"

print "Release safety checks passed."
