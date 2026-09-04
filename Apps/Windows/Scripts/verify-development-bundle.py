#!/usr/bin/env python3

"""Fail-closed inspection for the downloadable Windows development bundle."""

from __future__ import annotations

import argparse
import hashlib
import io
import pathlib
import re
import sys
import zipfile


ROOT_NAME = "FoundersOffice-Windows-x64-DEVELOPMENT"
FORBIDDEN_PARTS = {
    ".git",
    ".secrets",
    "appdata",
    "bin",
    "cache",
    "codex runs",
    "deriveddata",
    "generated",
    "obj",
    "personalization",
    "qa",
    "recovery",
    "support-bundles",
    "testresults",
}
FORBIDDEN_SUFFIXES = {
    ".bak",
    ".crash",
    ".env",
    ".jsonl",
    ".key",
    ".log",
    ".mobileprovision",
    ".p12",
    ".p8",
    ".pdb",
    ".pem",
    ".pfx",
    ".sqlite",
    ".sqlite3",
    ".trace",
}
PRIVATE_NAMES = {
    "openloops.json",
    "personalization.json",
    "open_loops_context.md",
}
PATH_MARKERS = (
    b"/Users/",
    b"\\Users\\",
    b"D:\\a\\founders-office\\founders-office\\",
    b"founders-office-worktrees",
)
SECRET_PATTERNS = (
    re.compile(rb"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
)
FIRST_PARTY_PACKAGE_FILES = {
    "appxmanifest.xml",
    "foundersoffice.app.dll",
    "foundersoffice.app.exe",
    "foundersoffice.core.dll",
    "resources.pri",
}


def fail(message: str) -> None:
    print(f"Windows development bundle verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def normalized_parts(name: str) -> tuple[str, ...]:
    path = pathlib.PurePosixPath(name.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or not path.parts:
        fail("archive contains an unsafe path")
    return tuple(part for part in path.parts if part not in ("", "."))


def validate_entry_name(name: str, *, require_root: bool) -> tuple[str, ...]:
    parts = normalized_parts(name)
    if require_root and parts[0] != ROOT_NAME:
        fail("every outer archive entry must stay under the labeled development folder")

    lowered = tuple(part.lower() for part in parts)
    if any(part in FORBIDDEN_PARTS for part in lowered):
        fail("archive contains a cache, runtime-data, or development-only directory")
    if lowered[-1] in PRIVATE_NAMES or pathlib.PurePosixPath(lowered[-1]).suffix in FORBIDDEN_SUFFIXES:
        fail("archive contains forbidden runtime data, credentials, logs, or debug files")
    return parts


def validate_zip_metadata(info: zipfile.ZipInfo) -> None:
    if info.file_size > 400 * 1024 * 1024:
        fail("archive contains an unexpectedly large file")
    if info.compress_size > 0 and info.file_size / info.compress_size > 250:
        fail("archive contains a suspicious compression ratio")
    unix_mode = info.external_attr >> 16
    if unix_mode and (unix_mode & 0o170000) == 0o120000:
        fail("archive contains a symbolic link")


def scan_bytes(data: bytes, *, context: str, scan_paths: bool = True) -> None:
    lowered = data.lower()
    if scan_paths:
        for marker in PATH_MARKERS:
            if marker.lower() in lowered or marker.decode("ascii").encode("utf-16le").lower() in lowered:
                fail(f"archive embeds a development-machine path in {context}")
    for pattern in SECRET_PATTERNS:
        if pattern.search(data):
            fail(f"archive contains possible credential material in {context}")


def inspect_nested_package(name: str, data: bytes, *, application: bool) -> None:
    try:
        package = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        fail(f"{name} is not a valid MSIX/AppX archive")

    package_names: set[str] = set()
    total_size = 0
    with package:
        for info in package.infolist():
            validate_zip_metadata(info)
            parts = validate_entry_name(info.filename, require_root=False)
            package_names.add("/".join(parts).lower())
            total_size += info.file_size
            if total_size > 900 * 1024 * 1024:
                fail("nested package expands beyond the reviewed size limit")
            if not info.is_dir():
                scan_bytes(
                    package.read(info),
                    context=f"{name}:{info.filename}",
                    scan_paths=pathlib.PurePosixPath(info.filename).name.lower()
                    in FIRST_PARTY_PACKAGE_FILES,
                )

        if application:
            if "appxmanifest.xml" not in package_names:
                fail("application MSIX is missing AppxManifest.xml")
            if "appxsignature.p7x" not in package_names:
                fail("application MSIX is not signed")
            manifest = package.read("AppxManifest.xml")
            if b'Name="FounderOffice.Windows.Development"' not in manifest:
                fail("application MSIX does not use the development identity")
            if b'Publisher="CN=FounderOfficeDevelopment"' not in manifest:
                fail("application MSIX publisher does not match the development certificate")


def verify_hash_manifest(files: dict[str, bytes]) -> None:
    manifest_name = f"{ROOT_NAME}/SHA256SUMS.txt"
    try:
        lines = files[manifest_name].decode("ascii").splitlines()
    except (KeyError, UnicodeDecodeError):
        fail("checksum manifest is missing or malformed")

    expected: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None or match.group(2) in expected:
            fail("checksum manifest has an invalid or duplicate entry")
        expected[match.group(2)] = match.group(1)

    actual = {
        name.removeprefix(f"{ROOT_NAME}/"): hashlib.sha256(data).hexdigest()
        for name, data in files.items()
        if name != manifest_name
    }
    if expected != actual:
        fail("checksum manifest does not exactly cover the bundle contents")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    args = parser.parse_args()

    if not args.archive.is_file() or args.archive.suffix.lower() != ".zip":
        fail("expected one ZIP archive")
    if args.archive.stat().st_size > 500 * 1024 * 1024:
        fail("outer archive exceeds the reviewed size limit")

    files: dict[str, bytes] = {}
    total_size = 0
    with zipfile.ZipFile(args.archive) as archive:
        for info in archive.infolist():
            validate_zip_metadata(info)
            parts = validate_entry_name(info.filename, require_root=True)
            if info.is_dir():
                continue
            name = "/".join(parts)
            if name in files:
                fail("outer archive contains a duplicate path")
            data = archive.read(info)
            files[name] = data
            total_size += len(data)
            if total_size > 900 * 1024 * 1024:
                fail("outer archive expands beyond the reviewed size limit")
            if pathlib.PurePosixPath(name).suffix.lower() not in (".appx", ".msix"):
                scan_bytes(data, context=name)

    required = {
        f"{ROOT_NAME}/BUILD-INFO.txt",
        f"{ROOT_NAME}/FounderOfficeDevelopment.cer",
        f"{ROOT_NAME}/FoundersOffice-Windows-x64-DEVELOPMENT.msix",
        f"{ROOT_NAME}/Install-Development.ps1",
        f"{ROOT_NAME}/README-DEVELOPMENT.md",
        f"{ROOT_NAME}/SHA256SUMS.txt",
    }
    if not required.issubset(files):
        fail("outer archive is missing required development-bundle files")

    verify_hash_manifest(files)
    application_name = f"{ROOT_NAME}/FoundersOffice-Windows-x64-DEVELOPMENT.msix"
    inspect_nested_package(application_name, files[application_name], application=True)
    for name, data in files.items():
        if name.startswith(f"{ROOT_NAME}/Dependencies/") and name.lower().endswith((".appx", ".msix")):
            inspect_nested_package(name, data, application=False)

    print("Windows development bundle archive passed content, signature, privacy, and path checks.")


if __name__ == "__main__":
    main()
