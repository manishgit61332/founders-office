#!/usr/bin/env python3

"""Create a write-once operator-confirmed clean-Mac acceptance record.

This command binds explicit human-observed checks to one exact sealed release.
It is deliberately not a cryptographic attestation and cannot replace the
physical clean-Mac run described in the distribution runbook.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
from pathlib import Path
import re
import uuid

from release_evidence_policy import (
    MAX_JSON_BYTES,
    PinnedRegularFile,
    ReleaseEvidenceError,
    bounded_text,
    canonical_https_origin,
    canonical_utc_timestamp,
    require_exact_immutable_url,
    strict_json_loads,
    validate_release_manifest,
    write_json_atomic,
)


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


def record_acceptance(arguments: argparse.Namespace) -> None:
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
        ):
            metadata_bytes = metadata_file.read_bytes()
            manifest = strict_json_loads(metadata_bytes, "canonical metadata")
            release = validate_release_manifest(manifest)
            if arguments.verified_artifact.name != release.artifact_name:
                raise ReleaseEvidenceError(
                    "verified artifact filename does not match canonical metadata"
                )

            actual_sha256 = artifact_file.sha256()
            if artifact_file.size != release.artifact_size or actual_sha256 != release.artifact_sha256:
                raise ReleaseEvidenceError(
                    "verified artifact bytes do not match canonical metadata"
                )

            origin = canonical_https_origin(arguments.approved_origin)
            release_path = (
                f"/releases/macos/v{release.version}/build-{release.build}/{release.commit}"
            )
            artifact_url = require_exact_immutable_url(
                arguments.artifact_url,
                origin,
                f"{release_path}/{release.artifact_name}",
                "artifact",
            )
            canonical_manifest_url = require_exact_immutable_url(
                arguments.canonical_manifest_url,
                origin,
                f"{release_path}/release.json",
                "canonical manifest",
            )
            acceptance_record_url = require_exact_immutable_url(
                arguments.acceptance_record_url,
                origin,
                f"{release_path}/clean-mac-acceptance.json",
                "acceptance record",
            )

            if not (
                arguments.confirm_clean_account
                and arguments.confirm_no_developer_certificate
                and arguments.confirm_no_source_checkout
            ):
                raise ReleaseEvidenceError(
                    "clean-account, certificate-absence, and source-absence confirmations are required"
                )

            passed_checks = arguments.passed
            if len(passed_checks) != len(set(passed_checks)):
                raise ReleaseEvidenceError("a clean-Mac check was confirmed more than once")
            missing_checks = sorted(set(REQUIRED_CHECKS) - set(passed_checks))
            if missing_checks:
                raise ReleaseEvidenceError(
                    "required checks did not pass: " + ", ".join(missing_checks)
                )

            try:
                parsed_acceptance_id = uuid.UUID(arguments.acceptance_id)
            except (ValueError, AttributeError) as error:
                raise ReleaseEvidenceError("acceptance ID is malformed") from error
            if parsed_acceptance_id.version != 4:
                raise ReleaseEvidenceError("acceptance ID must be a version-4 UUID")
            acceptance_id = str(parsed_acceptance_id)

            now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
            if arguments.tested_at:
                acceptance_tested_at = canonical_utc_timestamp(
                    arguments.tested_at, "test time"
                )
            else:
                acceptance_tested_at = now
            if acceptance_tested_at < release.created_at:
                raise ReleaseEvidenceError("acceptance cannot predate the sealed release")
            if acceptance_tested_at > now + datetime.timedelta(minutes=5):
                raise ReleaseEvidenceError("acceptance test time cannot be in the future")
            tested_at = acceptance_tested_at.strftime("%Y-%m-%dT%H:%M:%SZ")

            mac_model = bounded_text(arguments.mac_model, "Mac model", 64)
            macos_version = bounded_text(arguments.macos_version, "macOS version", 32)
            if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", macos_version):
                raise ReleaseEvidenceError("macOS version is malformed")

            acceptance = {
                "schemaVersion": 1,
                "writeOnce": True,
                "accepted": True,
                "attestationKind": "operator-confirmed",
                "acceptanceId": acceptance_id,
                "testedAt": tested_at,
                "release": {
                    "sourceManifestSHA256": hashlib.sha256(metadata_bytes).hexdigest(),
                    "artifactSHA256": actual_sha256,
                    "artifactSizeBytes": artifact_file.size,
                    "version": release.version,
                    "build": release.build,
                    "commit": release.commit,
                    "artifactURL": artifact_url,
                    "canonicalManifestURL": canonical_manifest_url,
                    "acceptanceRecordURL": acceptance_record_url,
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
            write_json_atomic(
                arguments.output,
                acceptance,
                write_once=True,
                reject_input_inodes=(metadata_file.inode, artifact_file.inode),
                mode=0o444,
            )
    except ReleaseEvidenceError as error:
        fail(str(error))

    print(f"Recorded clean-Mac acceptance: {arguments.output}")


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


if __name__ == "__main__":
    record_acceptance(parser.parse_args())
