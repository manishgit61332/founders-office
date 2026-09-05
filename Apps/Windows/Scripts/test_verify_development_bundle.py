#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import io
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT_NAME = "FoundersOffice-Windows-x64-DEVELOPMENT"
SCRIPT = pathlib.Path(__file__).with_name("verify-development-bundle.py")


def application_package(extra_files: dict[str, bytes] | None = None) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as package:
        package.writestr(
            "AppxManifest.xml",
            '<Package><Identity Name="FounderOffice.Windows.Development" '
            'Publisher="CN=FounderOfficeDevelopment" /></Package>',
        )
        package.writestr("AppxSignature.p7x", b"synthetic-signature-marker")
        for name, data in (extra_files or {}).items():
            package.writestr(name, data)
    return output.getvalue()


def write_bundle(path: pathlib.Path, *, package: bytes, extra_files: dict[str, bytes] | None = None) -> None:
    files = {
        "BUILD-INFO.txt": b"Founder's Office for Windows - DEVELOPMENT\n",
        "FounderOfficeDevelopment.cer": b"synthetic-public-certificate",
        "FoundersOffice-Windows-x64-DEVELOPMENT.msix": package,
        "Install-Development.ps1": b"Write-Host 'development fixture'\n",
        "README-DEVELOPMENT.md": b"Development fixture only.\n",
    }
    files.update(extra_files or {})
    checksums = "".join(
        f"{hashlib.sha256(data).hexdigest()}  {name}\n"
        for name, data in sorted(files.items())
    ).encode("ascii")
    files["SHA256SUMS.txt"] = checksums

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            archive.writestr(f"{ROOT_NAME}/{name}", data)


class DevelopmentBundleVerifierTests(unittest.TestCase):
    def run_verifier(self, archive: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(archive)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_exact_development_bundle_allow_list(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.zip"
            write_bundle(archive, package=application_package())

            result = self.run_verifier(archive)

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("passed", result.stdout)

    def test_rejects_development_machine_path_inside_msix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.zip"
            package = application_package(
                {"FoundersOffice.Core.dll": b"D:\\a\\founders-office\\founders-office\\source.cs"}
            )
            write_bundle(archive, package=package)

            result = self.run_verifier(archive)

            self.assertNotEqual(0, result.returncode)
            self.assertIn("development-machine path", result.stderr)

    def test_allows_upstream_provenance_path_in_third_party_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.zip"
            package = application_package(
                {"SQLitePCLRaw.core.dll": b"/Users/upstream/project/library.pdb"}
            )
            write_bundle(archive, package=package)

            result = self.run_verifier(archive)

            self.assertEqual(0, result.returncode, result.stderr)

    def test_rejects_private_signing_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.zip"
            write_bundle(
                archive,
                package=application_package(),
                extra_files={"signer.pfx": b"must-not-ship"},
            )

            result = self.run_verifier(archive)

            self.assertNotEqual(0, result.returncode)
            self.assertIn("forbidden", result.stderr)

    def test_rejects_local_auth_configuration_in_outer_or_nested_package(self) -> None:
        for nested in (False, True):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as directory:
                archive = pathlib.Path(directory) / "bundle.zip"
                local_config = {"Configuration/ProductAuth.local.json": b"{}"}
                write_bundle(
                    archive,
                    package=application_package(local_config if nested else None),
                    extra_files=None if nested else local_config,
                )

                result = self.run_verifier(archive)

                self.assertNotEqual(0, result.returncode)
                self.assertIn("forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
