#!/usr/bin/env python3

"""Strict, shared policy for Mac release evidence tooling.

The release and clean-Mac records are operational evidence, not cryptographic
attestations. These helpers make the local boundary deterministic: inputs are
opened once without following a final symlink, JSON is strict, URLs have one
canonical spelling, and output publication is atomic.
"""

from __future__ import annotations

from contextlib import AbstractContextManager
from dataclasses import dataclass
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any, Iterable
from urllib.parse import urlsplit
import uuid


MAX_JSON_BYTES = 1_048_576
MAX_SAFE_INTEGER = 9_007_199_254_740_991
RELEASE_MANIFEST_KEYS = {
    "schemaVersion",
    "writeOnce",
    "createdAt",
    "product",
    "release",
    "artifact",
    "signing",
    "notarization",
}


class ReleaseEvidenceError(ValueError):
    """A finite, operator-safe release evidence validation error."""


def exact_keys(value: Any, expected: set[str], label: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise ReleaseEvidenceError(f"{label} does not have the reviewed schema")


def _reject_duplicate_keys(label: str):
    def reject(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ReleaseEvidenceError(f"duplicate {label} key: {key}")
            result[key] = value
        return result

    return reject


def strict_json_loads(data: bytes, label: str) -> Any:
    if len(data) > MAX_JSON_BYTES:
        raise ReleaseEvidenceError(f"{label} exceeds 1 MiB")
    try:
        text = data.decode("utf-8")
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys(label),
            parse_constant=lambda token: (_ for _ in ()).throw(
                ReleaseEvidenceError(f"{label} contains non-standard JSON value: {token}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseEvidenceError(f"{label} is invalid JSON: {error}") from error


def canonical_utc_timestamp(value: Any, label: str) -> datetime.datetime:
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value
    ):
        raise ReleaseEvidenceError(f"{label} is malformed")
    try:
        parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError as error:
        raise ReleaseEvidenceError(f"{label} is malformed") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ReleaseEvidenceError(f"{label} is not canonical UTC")
    return parsed


def canonical_uuid(value: Any, label: str, *, required_version: int | None = None) -> str:
    if not isinstance(value, str):
        raise ReleaseEvidenceError(f"{label} is malformed")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ReleaseEvidenceError(f"{label} is malformed") from error
    if str(parsed) != value or (required_version is not None and parsed.version != required_version):
        raise ReleaseEvidenceError(f"{label} is not canonical")
    return value


def bounded_text(value: Any, label: str, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or len(value) > maximum
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        raise ReleaseEvidenceError(f"{label} is malformed")
    return value


@dataclass(frozen=True)
class ValidatedRelease:
    created_at: datetime.datetime
    version: str
    build: str
    build_number: int
    commit: str
    artifact_name: str
    artifact_sha256: str
    artifact_size: int
    team_id: str


def validate_release_manifest(manifest: Any) -> ValidatedRelease:
    exact_keys(manifest, RELEASE_MANIFEST_KEYS, "canonical metadata")
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 2:
        raise ReleaseEvidenceError("canonical metadata schema version is malformed")
    if manifest.get("writeOnce") is not True:
        raise ReleaseEvidenceError("canonical metadata is not write-once")
    created_at = canonical_utc_timestamp(manifest.get("createdAt"), "release time")

    product = manifest.get("product")
    release = manifest.get("release")
    artifact = manifest.get("artifact")
    signing = manifest.get("signing")
    notarization = manifest.get("notarization")
    exact_keys(
        product,
        {
            "name",
            "bundleIdentifier",
            "cloudEnabled",
            "syncAuthority",
            "minimumSystemVersion",
            "architectures",
        },
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

    bundle_identifier = bounded_text(product.get("bundleIdentifier"), "bundle identifier", 255)
    sync_authority = bounded_text(product.get("syncAuthority"), "sync authority", 32)
    minimum_system_version = product.get("minimumSystemVersion")
    architectures = product.get("architectures")
    if (
        product.get("name") != "Founder's Office"
        or product.get("cloudEnabled") is not True
        or sync_authority != "supabase"
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", bundle_identifier)
        or ".." in bundle_identifier
        or not isinstance(minimum_system_version, str)
        or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum_system_version)
        or not isinstance(architectures, list)
        or not architectures
        or len(architectures) != len(set(architectures))
        or any(type(item) is not str or item not in {"arm64", "x86_64"} for item in architectures)
    ):
        raise ReleaseEvidenceError("canonical product identity is malformed")

    version = release.get("version")
    build = release.get("build")
    commit = release.get("commit")
    if (
        not isinstance(version, str)
        or len(version) > 32
        or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version)
        or not isinstance(build, str)
        or len(build) > 15
        or not re.fullmatch(r"[1-9][0-9]*", build)
        or int(build) > MAX_SAFE_INTEGER
        or not isinstance(commit, str)
        or not re.fullmatch(r"[0-9a-f]{40}", commit)
        or release.get("tag") != f"v{version}"
        or release.get("record") != "release-record.md"
    ):
        raise ReleaseEvidenceError("canonical release identity is malformed")

    artifact_name = f"FoundersOffice-{version}-build-{build}-macOS.zip"
    artifact_sha256 = artifact.get("sha256")
    artifact_size = artifact.get("sizeBytes")
    if (
        artifact.get("fileName") != artifact_name
        or artifact.get("format") != "zip"
        or not isinstance(artifact_sha256, str)
        or not re.fullmatch(r"[0-9a-f]{64}", artifact_sha256)
        or type(artifact_size) is not int
        or not 1 <= artifact_size <= MAX_SAFE_INTEGER
    ):
        raise ReleaseEvidenceError("canonical artifact identity is malformed")

    team_id = signing.get("teamIdentifier")
    identity = signing.get("identity")
    if (
        not isinstance(team_id, str)
        or not re.fullmatch(r"[A-Z0-9]{10}", team_id)
        or not isinstance(identity, str)
        or len(identity) > 200
        or not re.fullmatch(
            rf"Developer ID Application: [^\x00-\x1f\x7f]{{1,160}} \({re.escape(team_id)}\)",
            identity,
        )
        or signing.get("hardenedRuntime") is not True
        or signing.get("timestamped") is not True
    ):
        raise ReleaseEvidenceError("canonical signing identity is malformed")

    canonical_uuid(notarization.get("submissionId"), "notarization submission ID")
    if (
        notarization.get("status") != "Accepted"
        or notarization.get("ticketStapled") is not True
        or notarization.get("gatekeeperAssessment") != "accepted"
    ):
        raise ReleaseEvidenceError("canonical notarization evidence is malformed")

    return ValidatedRelease(
        created_at=created_at,
        version=version,
        build=build,
        build_number=int(build),
        commit=commit,
        artifact_name=artifact_name,
        artifact_sha256=artifact_sha256,
        artifact_size=artifact_size,
        team_id=team_id,
    )


def canonical_https_origin(value: Any) -> str:
    if not isinstance(value, str) or not value or len(value) > 512:
        raise ReleaseEvidenceError("approved origin must be one canonical bare HTTPS origin")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise ReleaseEvidenceError("approved origin must be one canonical bare HTTPS origin") from error
    if (
        parsed.scheme != "https"
        or hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path != ""
        or parsed.query
        or parsed.fragment
        or port == 443
        or len(hostname) > 253
    ):
        raise ReleaseEvidenceError("approved origin must be one canonical bare HTTPS origin")
    labels = hostname.split(".")
    if any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in labels
    ):
        raise ReleaseEvidenceError("approved origin host must be canonical lowercase ASCII")
    canonical = f"https://{hostname}"
    if port is not None:
        canonical += f":{port}"
    if value != canonical:
        raise ReleaseEvidenceError("approved origin must use its exact canonical spelling")
    return canonical


def require_exact_immutable_url(value: Any, origin: str, path: str, label: str) -> str:
    expected = f"{origin}{path}"
    if not isinstance(value, str) or len(value) > 2048 or value != expected:
        raise ReleaseEvidenceError(f"{label} URL is not the exact immutable release path")
    return value


class PinnedRegularFile(AbstractContextManager["PinnedRegularFile"]):
    """A regular file descriptor pinned before validation and hashing."""

    def __init__(self, path: Path, label: str, *, maximum_size: int | None = None):
        self.path = path
        self.label = label
        self.maximum_size = maximum_size
        self.fd: int | None = None
        self.stat: os.stat_result | None = None

    def __enter__(self) -> "PinnedRegularFile":
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            self.fd = os.open(self.path, flags)
            self.stat = os.fstat(self.fd)
        except OSError as error:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            raise ReleaseEvidenceError(
                f"{self.label} must be a readable regular, non-symlink file"
            ) from error
        if not stat.S_ISREG(self.stat.st_mode):
            self.close()
            raise ReleaseEvidenceError(f"{self.label} must be a regular, non-symlink file")
        if self.maximum_size is not None and self.stat.st_size > self.maximum_size:
            self.close()
            raise ReleaseEvidenceError(f"{self.label} exceeds 1 MiB")
        return self

    @property
    def inode(self) -> tuple[int, int]:
        assert self.stat is not None
        return (self.stat.st_dev, self.stat.st_ino)

    @property
    def size(self) -> int:
        assert self.stat is not None
        return self.stat.st_size

    def _rewind(self) -> None:
        assert self.fd is not None
        os.lseek(self.fd, 0, os.SEEK_SET)

    def _assert_stable(self) -> None:
        assert self.fd is not None and self.stat is not None
        current = os.fstat(self.fd)
        if (
            current.st_dev != self.stat.st_dev
            or current.st_ino != self.stat.st_ino
            or current.st_size != self.stat.st_size
            or current.st_mtime_ns != self.stat.st_mtime_ns
            or current.st_ctime_ns != self.stat.st_ctime_ns
        ):
            raise ReleaseEvidenceError(f"{self.label} changed while it was being verified")

    def read_bytes(self) -> bytes:
        self._rewind()
        chunks = []
        total = 0
        while True:
            assert self.fd is not None
            chunk = os.read(self.fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if self.maximum_size is not None and total > self.maximum_size:
                raise ReleaseEvidenceError(f"{self.label} exceeds 1 MiB")
        self._assert_stable()
        if total != self.size:
            raise ReleaseEvidenceError(f"{self.label} changed while it was being read")
        return b"".join(chunks)

    def sha256(self) -> str:
        self._rewind()
        digest = hashlib.sha256()
        total = 0
        while True:
            assert self.fd is not None
            chunk = os.read(self.fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            total += len(chunk)
        self._assert_stable()
        if total != self.size:
            raise ReleaseEvidenceError(f"{self.label} changed while it was being hashed")
        return digest.hexdigest()

    def close(self) -> None:
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


def _open_output_parent(output: Path) -> tuple[int, str]:
    absolute = os.path.abspath(os.fspath(output))
    parent, name = os.path.split(absolute)
    if not name or name in {".", ".."}:
        raise ReleaseEvidenceError("output path is malformed")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        return os.open(parent, flags), name
    except OSError as error:
        raise ReleaseEvidenceError(
            "output parent must already be a real, non-symlink directory"
        ) from error


def _destination_stat(parent_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def write_json_atomic(
    output: Path,
    value: Any,
    *,
    write_once: bool,
    reject_input_inodes: Iterable[tuple[int, int]] = (),
    mode: int = 0o644,
) -> None:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    parent_fd, name = _open_output_parent(output)
    temp_name = f".{name}.{uuid.uuid4().hex}.tmp"
    temp_fd: int | None = None
    reject = set(reject_input_inodes)
    try:
        destination = _destination_stat(parent_fd, name)
        if destination is not None:
            if write_once:
                raise ReleaseEvidenceError("the acceptance output is write-once and already exists")
            if stat.S_ISLNK(destination.st_mode) or not stat.S_ISREG(destination.st_mode):
                raise ReleaseEvidenceError("output must be absent or a regular, non-symlink file")
            if (destination.st_dev, destination.st_ino) in reject:
                raise ReleaseEvidenceError("output must not replace release evidence input")

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        temp_fd = os.open(temp_name, flags, mode, dir_fd=parent_fd)
        written = 0
        while written < len(payload):
            written += os.write(temp_fd, payload[written:])
        os.fsync(temp_fd)
        os.fchmod(temp_fd, mode)
        os.close(temp_fd)
        temp_fd = None

        if write_once:
            try:
                os.link(
                    temp_name,
                    name,
                    src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd,
                    follow_symlinks=False,
                )
            except FileExistsError as error:
                raise ReleaseEvidenceError(
                    "the acceptance output is write-once and already exists"
                ) from error
            os.unlink(temp_name, dir_fd=parent_fd)
        else:
            destination = _destination_stat(parent_fd, name)
            if destination is not None and (destination.st_dev, destination.st_ino) in reject:
                raise ReleaseEvidenceError("output must not replace release evidence input")
            os.replace(temp_name, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise ReleaseEvidenceError("output path must not be a symlink") from error
        raise
    finally:
        if temp_fd is not None:
            os.close(temp_fd)
        try:
            os.unlink(temp_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        os.close(parent_fd)
