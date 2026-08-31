#!/usr/bin/env python3

"""Create a write-once clean-Mac acceptance record for one sealed release.

This tool deliberately does not make the acceptance checks automatic. The
checks include physical restart, permission, upgrade, and recovery exercises
that require a clean test Mac and a human-observed outcome. Requiring every
explicit confirmation makes an omitted gate fail closed instead of silently
turning a notarized build into a public download.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
from urllib.parse import urlparse
import uuid


REQUIRED_CHECKS = (
    "immutablePublicOriginDownload",
    "independentReleaseVerification",
    "cleanInstall",
    "gatekeeperLaunch",
    "onboarding",
    "calendarPermissionRetention",
    "launchAtLoginRestart",
    "signedUpgradeDataRetention",
    "workspaceExport",
    "workspaceErase",
    "recovery",
    "stagedUpdate",
    "pausedUpdate",
    "correctiveRollbackEvidence",
)


def fail(message: str) -> None:
    raise SystemExit(f"Clean-Mac acceptance failed: {message}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate canonical manifest key: {key}")
        result[key] = value
    return result


def exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"{label} does not have the reviewed schema")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_text(value: str, label: str, maximum: int) -> str:
    if (
        not value
        or value != value.strip()
        or len(value) > maximum
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        fail(f"{label} is malformed")
    return value


parser = argparse.ArgumentParser()
parser.add_argument("--metadata", required=True, type=Path)
parser.add_argument("--verified-artifact", required=True, type=Path)
parser.add_argument("--approved-origin", required=True)
parser.add_argument("--artifact-url", required=True)
parser.add_argument("--canonical-manifest-url", required=True)
parser.add_argument("--acceptance-record-url", required=True)
parser.add_argument("--mac-model", required=True)
parser.add_argument("--macos-version", required=True)
parser.add_argument("--acceptance-id", default=str(uuid.uuid4()))
parser.add_argument("--tested-at")
parser.add_argument("--confirm-clean-account", action="store_true")
parser.add_argument("--confirm-no-developer-certificate", action="store_true")
parser.add_argument("--confirm-no-source-checkout", action="store_true")
parser.add_argument(
    "--passed",
    action="append",
    default=[],
    choices=REQUIRED_CHECKS,
    metavar="CHECK",
)
parser.add_argument("--output", required=True, type=Path)
arguments = parser.parse_args()

for path, label in (
    (arguments.metadata, "canonical metadata"),
    (arguments.verified_artifact, "verified artifact"),
):
    if not path.is_file() or path.is_symlink():
        fail(f"{label} must be a regular, non-symlink file")

if arguments.output.exists() or arguments.output.is_symlink():
    fail("the acceptance output is write-once and already exists")
if arguments.metadata.stat().st_size > 1_048_576:
    fail("canonical metadata exceeds 1 MiB")

metadata_bytes = arguments.metadata.read_bytes()
try:
    manifest = json.loads(metadata_bytes, object_pairs_hook=reject_duplicate_keys)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"canonical metadata is invalid JSON: {error}")

exact_keys(
    manifest,
    {
        "schemaVersion",
        "writeOnce",
        "createdAt",
        "product",
        "release",
        "artifact",
        "signing",
        "notarization",
    },
    "canonical metadata",
)
if manifest.get("schemaVersion") != 1 or manifest.get("writeOnce") is not True:
    fail("canonical metadata is not a write-once schema-1 record")

release = manifest.get("release")
artifact = manifest.get("artifact")
product = manifest.get("product")
signing = manifest.get("signing")
notarization = manifest.get("notarization")
exact_keys(
    product,
    {"name", "bundleIdentifier", "cloudEnabled", "iCloudContainer", "minimumSystemVersion", "architectures"},
    "product",
)
exact_keys(release, {"version", "build", "tag", "commit", "record"}, "release")
exact_keys(artifact, {"fileName", "format", "sha256", "sizeBytes"}, "artifact")
exact_keys(signing, {"identity", "teamIdentifier", "hardenedRuntime", "timestamped"}, "signing")
exact_keys(
    notarization,
    {"submissionId", "status", "ticketStapled", "gatekeeperAssessment"},
    "notarization",
)

version = release.get("version")
build = release.get("build")
commit = release.get("commit")
artifact_sha256 = artifact.get("sha256")
artifact_size = artifact.get("sizeBytes")
if (
    not isinstance(version, str)
    or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
    or not isinstance(build, str)
    or not re.fullmatch(r"[1-9][0-9]*", build)
    or not isinstance(commit, str)
    or not re.fullmatch(r"[0-9a-f]{40}", commit)
    or not isinstance(artifact_sha256, str)
    or not re.fullmatch(r"[0-9a-f]{64}", artifact_sha256)
    or isinstance(artifact_size, bool)
    or not isinstance(artifact_size, int)
    or artifact_size < 1
):
    fail("canonical release identity is malformed")
if (
    product.get("name") != "Founder's Office"
    or product.get("cloudEnabled") is not True
    or release.get("tag") != f"v{version}"
    or release.get("record") != "release-record.md"
    or artifact.get("format") != "zip"
    or artifact.get("fileName") != f"FoundersOffice-{version}-build-{build}-macOS.zip"
    or arguments.verified_artifact.name != artifact.get("fileName")
    or not isinstance(signing.get("identity"), str)
    or not signing["identity"].startswith("Developer ID Application:")
    or signing.get("hardenedRuntime") is not True
    or signing.get("timestamped") is not True
    or notarization.get("status") != "Accepted"
    or notarization.get("ticketStapled") is not True
    or notarization.get("gatekeeperAssessment") != "accepted"
):
    fail("canonical metadata does not describe a sealed customer release")

origin = urlparse(arguments.approved_origin)
artifact_url = urlparse(arguments.artifact_url)
manifest_url = urlparse(arguments.canonical_manifest_url)
acceptance_url = urlparse(arguments.acceptance_record_url)
release_path = f"/releases/macos/v{version}/build-{build}/{commit}"
expected_urls = {
    "artifact": (artifact_url, f"{release_path}/{artifact['fileName']}"),
    "canonical manifest": (manifest_url, f"{release_path}/release.json"),
    "acceptance record": (acceptance_url, f"{release_path}/clean-mac-acceptance.json"),
}
if (
    origin.scheme != "https"
    or origin.hostname is None
    or not origin.netloc
    or origin.username is not None
    or origin.password is not None
    or origin.path not in {"", "/"}
    or origin.params
    or origin.query
    or origin.fragment
):
    fail("approved origin must be a bare HTTPS origin")
for label, (candidate, expected_path) in expected_urls.items():
    if (
        candidate.scheme != "https"
        or candidate.netloc != origin.netloc
        or candidate.username is not None
        or candidate.password is not None
        or candidate.path != expected_path
        or candidate.params
        or candidate.query
        or candidate.fragment
    ):
        fail(f"{label} URL is not the exact immutable release path")

actual_size = arguments.verified_artifact.stat().st_size
actual_sha256 = sha256_file(arguments.verified_artifact)
if actual_size != artifact_size or actual_sha256 != artifact_sha256:
    fail("verified artifact bytes do not match canonical metadata")

if not (
    arguments.confirm_clean_account
    and arguments.confirm_no_developer_certificate
    and arguments.confirm_no_source_checkout
):
    fail("clean-account, certificate-absence, and source-absence confirmations are required")

passed_checks = arguments.passed
if len(passed_checks) != len(set(passed_checks)):
    fail("a clean-Mac check was confirmed more than once")
missing_checks = sorted(set(REQUIRED_CHECKS) - set(passed_checks))
if missing_checks:
    fail("required checks did not pass: " + ", ".join(missing_checks))

try:
    acceptance_id = str(uuid.UUID(arguments.acceptance_id)).lower()
except (ValueError, AttributeError):
    fail("acceptance ID is malformed")

if arguments.tested_at:
    tested_at = arguments.tested_at
    try:
        datetime.datetime.strptime(tested_at, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        fail("test time is malformed")
else:
    tested_at = datetime.datetime.now(datetime.UTC).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
try:
    release_created_at = datetime.datetime.strptime(
        manifest.get("createdAt", ""), "%Y-%m-%dT%H:%M:%SZ"
    )
    acceptance_tested_at = datetime.datetime.strptime(tested_at, "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    fail("release or acceptance time is malformed")
if acceptance_tested_at < release_created_at:
    fail("acceptance cannot predate the sealed release")

mac_model = bounded_text(arguments.mac_model, "Mac model", 64)
macos_version = bounded_text(arguments.macos_version, "macOS version", 32)
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", macos_version):
    fail("macOS version is malformed")

acceptance = {
    "schemaVersion": 1,
    "writeOnce": True,
    "accepted": True,
    "acceptanceId": acceptance_id,
    "testedAt": tested_at,
    "release": {
        "sourceManifestSHA256": hashlib.sha256(metadata_bytes).hexdigest(),
        "artifactSHA256": actual_sha256,
        "artifactSizeBytes": actual_size,
        "version": version,
        "build": build,
        "commit": commit,
        "artifactURL": arguments.artifact_url,
        "canonicalManifestURL": arguments.canonical_manifest_url,
        "acceptanceRecordURL": arguments.acceptance_record_url,
    },
    "environment": {
        "macModel": mac_model,
        "macOSVersion": macos_version,
        "cleanAccount": True,
        "developerCertificateAbsent": True,
        "sourceCheckoutAbsent": True,
    },
    "checks": {name: "passed" for name in REQUIRED_CHECKS},
}

arguments.output.parent.mkdir(parents=True, exist_ok=True)
temporary = arguments.output.with_name(f".{arguments.output.name}.{os.getpid()}.tmp")
try:
    temporary.write_text(json.dumps(acceptance, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o444)
    os.replace(temporary, arguments.output)
finally:
    temporary.unlink(missing_ok=True)

print(f"Recorded clean-Mac acceptance: {arguments.output}")
