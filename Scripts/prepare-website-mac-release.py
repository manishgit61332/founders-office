#!/usr/bin/env python3

"""Generate the website download gate from pinned Mac release evidence."""

from __future__ import annotations

import argparse
import datetime
import hashlib
from pathlib import Path
import re

from release_evidence_policy import (
    MAX_JSON_BYTES,
    PinnedRegularFile,
    ReleaseEvidenceError,
    bounded_text,
    canonical_https_origin,
    canonical_utc_timestamp,
    canonical_uuid,
    exact_keys,
    require_exact_immutable_url,
    strict_json_loads,
    validate_release_manifest,
    write_json_atomic,
)


REQUIRED_CHECKS = {
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
}


def fail(message: str) -> None:
    raise SystemExit(f"Website release preparation failed: {message}")


def prepare_release(arguments: argparse.Namespace) -> None:
    try:
        with (
            PinnedRegularFile(
                arguments.metadata,
                "canonical metadata",
                maximum_size=MAX_JSON_BYTES,
            ) as metadata_file,
            PinnedRegularFile(
                arguments.verified_artifact,
                "verified artifact",
            ) as artifact_file,
            PinnedRegularFile(
                arguments.clean_mac_acceptance,
                "clean-Mac acceptance record",
                maximum_size=MAX_JSON_BYTES,
            ) as acceptance_file,
        ):
            metadata_bytes = metadata_file.read_bytes()
            manifest = strict_json_loads(metadata_bytes, "canonical metadata")
            release = validate_release_manifest(manifest)
            if arguments.verified_artifact.name != release.artifact_name:
                raise ReleaseEvidenceError(
                    "verified artifact filename does not match canonical metadata"
                )
            artifact_sha256 = artifact_file.sha256()
            if artifact_file.size != release.artifact_size or artifact_sha256 != release.artifact_sha256:
                raise ReleaseEvidenceError(
                    "verified artifact bytes do not match canonical metadata"
                )

            acceptance_bytes = acceptance_file.read_bytes()
            acceptance = strict_json_loads(
                acceptance_bytes, "clean-Mac acceptance record"
            )
            exact_keys(
                acceptance,
                {
                    "schemaVersion",
                    "writeOnce",
                    "accepted",
                    "attestationKind",
                    "acceptanceId",
                    "testedAt",
                    "release",
                    "environment",
                    "checks",
                },
                "clean-Mac acceptance record",
            )
            if (
                type(acceptance.get("schemaVersion")) is not int
                or acceptance["schemaVersion"] != 1
                or acceptance.get("writeOnce") is not True
                or acceptance.get("accepted") is not True
                or acceptance.get("attestationKind") != "operator-confirmed"
            ):
                raise ReleaseEvidenceError(
                    "clean-Mac acceptance record is not an operator-confirmed write-once schema-1 record"
                )
            canonical_uuid(
                acceptance.get("acceptanceId"),
                "clean-Mac acceptance ID",
                required_version=4,
            )
            acceptance_tested_at = canonical_utc_timestamp(
                acceptance.get("testedAt"), "clean-Mac acceptance time"
            )
            if acceptance_tested_at < release.created_at:
                raise ReleaseEvidenceError(
                    "clean-Mac acceptance predates the sealed release"
                )
            now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
            if acceptance_tested_at > now + datetime.timedelta(minutes=5):
                raise ReleaseEvidenceError(
                    "clean-Mac acceptance time cannot be in the future"
                )

            accepted_release = acceptance.get("release")
            exact_keys(
                accepted_release,
                {
                    "sourceManifestSHA256",
                    "artifactSHA256",
                    "artifactSizeBytes",
                    "version",
                    "build",
                    "commit",
                    "artifactURL",
                    "canonicalManifestURL",
                    "acceptanceRecordURL",
                },
                "clean-Mac accepted release",
            )
            accepted_release_identity = {
                "sourceManifestSHA256": hashlib.sha256(metadata_bytes).hexdigest(),
                "artifactSHA256": artifact_sha256,
                "artifactSizeBytes": artifact_file.size,
                "version": release.version,
                "build": release.build,
                "commit": release.commit,
            }
            if any(
                accepted_release.get(key) != value
                for key, value in accepted_release_identity.items()
            ):
                raise ReleaseEvidenceError(
                    "clean-Mac acceptance does not match the canonical release and artifact"
                )

            accepted_environment = acceptance.get("environment")
            exact_keys(
                accepted_environment,
                {
                    "macModel",
                    "macOSVersion",
                    "cleanAccount",
                    "developerCertificateAbsent",
                    "sourceCheckoutAbsent",
                },
                "clean-Mac acceptance environment",
            )
            bounded_text(
                accepted_environment.get("macModel"), "clean-Mac model", 64
            )
            macos_version = bounded_text(
                accepted_environment.get("macOSVersion"),
                "clean-Mac macOS version",
                32,
            )
            if (
                not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", macos_version)
                or accepted_environment.get("cleanAccount") is not True
                or accepted_environment.get("developerCertificateAbsent") is not True
                or accepted_environment.get("sourceCheckoutAbsent") is not True
            ):
                raise ReleaseEvidenceError(
                    "clean-Mac acceptance environment is malformed or not clean"
                )

            accepted_checks = acceptance.get("checks")
            if not isinstance(accepted_checks, dict) or set(accepted_checks) != REQUIRED_CHECKS:
                raise ReleaseEvidenceError(
                    "clean-Mac checks do not have the reviewed schema"
                )
            failed_checks = sorted(
                name for name, outcome in accepted_checks.items() if outcome != "passed"
            )
            if failed_checks:
                raise ReleaseEvidenceError(
                    "clean-Mac check did not pass: " + ", ".join(failed_checks)
                )

            origin = canonical_https_origin(arguments.approved_origin)
            release_base_path = (
                f"/releases/macos/v{release.version}/build-{release.build}/{release.commit}"
            )
            download_url = require_exact_immutable_url(
                arguments.download_url,
                origin,
                f"{release_base_path}/{release.artifact_name}",
                "download",
            )
            artifact_url = require_exact_immutable_url(
                accepted_release.get("artifactURL"),
                origin,
                f"{release_base_path}/{release.artifact_name}",
                "clean-Mac artifact",
            )
            canonical_manifest_url = require_exact_immutable_url(
                accepted_release.get("canonicalManifestURL"),
                origin,
                f"{release_base_path}/release.json",
                "clean-Mac canonical manifest",
            )
            acceptance_record_url = require_exact_immutable_url(
                accepted_release.get("acceptanceRecordURL"),
                origin,
                f"{release_base_path}/clean-mac-acceptance.json",
                "clean-Mac acceptance record",
            )
            if artifact_url != download_url:
                raise ReleaseEvidenceError(
                    "website download URL differs from the clean-Mac tested artifact URL"
                )

            website_manifest = {
                "schemaVersion": 2,
                "available": True,
                "verifiedFromCanonicalManifest": True,
                "signedAndNotarized": True,
                "cleanMacAccepted": True,
                "acceptanceAttestation": "operator-confirmed",
                "version": release.version,
                "build": release.build_number,
                "teamID": release.team_id,
                "sha256": artifact_sha256,
                "artifactFileName": release.artifact_name,
                "artifactSizeBytes": artifact_file.size,
                "releaseCommit": release.commit,
                "sourceManifestSHA256": hashlib.sha256(metadata_bytes).hexdigest(),
                "acceptanceRecordSHA256": hashlib.sha256(acceptance_bytes).hexdigest(),
                "canonicalManifestURL": canonical_manifest_url,
                "acceptanceRecordURL": acceptance_record_url,
                "downloadURL": download_url,
            }
            write_json_atomic(
                arguments.output,
                website_manifest,
                write_once=False,
                reject_input_inodes=(
                    metadata_file.inode,
                    artifact_file.inode,
                    acceptance_file.inode,
                ),
            )
    except ReleaseEvidenceError as error:
        fail(str(error))

    print(f"Prepared fail-closed website release manifest: {arguments.output}")


parser = argparse.ArgumentParser()
parser.add_argument("--metadata", required=True, type=Path)
parser.add_argument("--verified-artifact", required=True, type=Path)
parser.add_argument("--clean-mac-acceptance", required=True, type=Path)
parser.add_argument("--download-url", required=True)
parser.add_argument("--approved-origin", required=True)
parser.add_argument("--output", required=True, type=Path)


if __name__ == "__main__":
    prepare_release(parser.parse_args())
