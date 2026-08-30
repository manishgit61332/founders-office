#!/usr/bin/env python3

"""Generate the website download gate from a sealed, verified Mac release."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
from urllib.parse import urlparse


def fail(message: str) -> None:
    raise SystemExit(f"Website release preparation failed: {message}")


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


parser = argparse.ArgumentParser()
parser.add_argument("--metadata", required=True, type=Path)
parser.add_argument("--verified-artifact", required=True, type=Path)
parser.add_argument("--download-url", required=True)
parser.add_argument("--approved-origin", required=True)
parser.add_argument("--output", required=True, type=Path)
arguments = parser.parse_args()

for path, label in [
    (arguments.metadata, "canonical metadata"),
    (arguments.verified_artifact, "verified artifact"),
]:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} must be a regular, non-symlink file")

if arguments.metadata.stat().st_size > 1_048_576:
    fail("canonical metadata exceeds 1 MiB")

metadata_bytes = arguments.metadata.read_bytes()
try:
    manifest = json.loads(metadata_bytes, object_pairs_hook=reject_duplicate_keys)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"canonical metadata is invalid JSON: {error}")

exact_keys(
    manifest,
    {"schemaVersion", "writeOnce", "createdAt", "product", "release", "artifact", "signing", "notarization"},
    "canonical metadata",
)
if manifest["schemaVersion"] != 1 or manifest["writeOnce"] is not True:
    fail("canonical metadata is not a write-once schema-1 record")
try:
    datetime.datetime.strptime(manifest.get("createdAt", ""), "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    fail("canonical metadata creation time is malformed")

product = manifest["product"]
release = manifest["release"]
artifact = manifest["artifact"]
signing = manifest["signing"]
notarization = manifest["notarization"]
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
team_id = signing.get("teamIdentifier")
if product.get("name") != "Founder's Office" or product.get("cloudEnabled") is not True:
    fail("canonical metadata does not describe the cloud-enabled product")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail("version is malformed")
if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
    fail("build is malformed")
if release.get("tag") != f"v{version}" or not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    fail("release tag or commit is malformed")
if not isinstance(team_id, str) or not re.fullmatch(r"[A-Z0-9]{10}", team_id):
    fail("Team ID is malformed")
if not isinstance(signing.get("identity"), str) or not signing["identity"].startswith("Developer ID Application:"):
    fail("Developer ID signing identity is malformed")
if signing.get("hardenedRuntime") is not True or signing.get("timestamped") is not True:
    fail("release is not hardened and timestamped")
if (
    notarization.get("status") != "Accepted"
    or notarization.get("ticketStapled") is not True
    or notarization.get("gatekeeperAssessment") != "accepted"
):
    fail("release is not accepted, stapled, and Gatekeeper-approved")

expected_name = f"FoundersOffice-{version}-build-{build}-macOS.zip"
if artifact.get("fileName") != expected_name or artifact.get("format") != "zip":
    fail("artifact name or format is not canonical")
if arguments.verified_artifact.name != expected_name:
    fail("verified artifact filename does not match metadata")

artifact_size = arguments.verified_artifact.stat().st_size
artifact_sha256 = sha256_file(arguments.verified_artifact)
if (
    isinstance(artifact.get("sizeBytes"), bool)
    or not isinstance(artifact.get("sizeBytes"), int)
    or artifact_size != artifact.get("sizeBytes")
    or not isinstance(artifact.get("sha256"), str)
    or not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
    or artifact_sha256 != artifact["sha256"]
):
    fail("verified artifact bytes do not match canonical metadata")

origin = urlparse(arguments.approved_origin)
download = urlparse(arguments.download_url)
expected_path = f"/releases/macos/v{version}/build-{build}/{commit}/{expected_name}"
if (
    origin.scheme != "https"
    or origin.username is not None
    or origin.password is not None
    or origin.path not in {"", "/"}
    or origin.params
    or origin.query
    or origin.fragment
):
    fail("approved origin must be a bare HTTPS origin")
if (
    download.scheme != "https"
    or download.netloc != origin.netloc
    or download.username is not None
    or download.password is not None
    or download.path != expected_path
    or download.params
    or download.query
    or download.fragment
):
    fail("download URL is not the exact immutable release path on the approved origin")

website_manifest = {
    "schemaVersion": 1,
    "available": True,
    "verifiedFromCanonicalManifest": True,
    "signedAndNotarized": True,
    "version": version,
    "build": int(build),
    "teamID": team_id,
    "sha256": artifact_sha256,
    "artifactFileName": expected_name,
    "artifactSizeBytes": artifact_size,
    "releaseCommit": commit,
    "sourceManifestSHA256": hashlib.sha256(metadata_bytes).hexdigest(),
    "downloadURL": arguments.download_url,
}

arguments.output.parent.mkdir(parents=True, exist_ok=True)
temporary = arguments.output.with_name(f".{arguments.output.name}.{os.getpid()}.tmp")
try:
    temporary.write_text(json.dumps(website_manifest, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, arguments.output)
finally:
    temporary.unlink(missing_ok=True)

print(f"Prepared fail-closed website release manifest: {arguments.output}")
