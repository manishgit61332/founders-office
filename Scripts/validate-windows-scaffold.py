#!/usr/bin/env python3

"""Credential-free structural gate for the native Windows milestone."""

from __future__ import annotations

import json
import pathlib
import sys
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "Apps" / "Windows"


def fail(message: str) -> None:
    print(f"Windows scaffold validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


required_files = [
    WINDOWS / "global.json",
    WINDOWS / "Directory.Packages.props",
    WINDOWS / "FoundersOffice.Windows.slnx",
    WINDOWS / "README.md",
    WINDOWS / "src" / "FoundersOffice.Core" / "FoundersOffice.Core.csproj",
    WINDOWS / "src" / "FoundersOffice.Core" / "packages.lock.json",
    WINDOWS / "src" / "FoundersOffice.App" / "FoundersOffice.App.csproj",
    WINDOWS / "src" / "FoundersOffice.App" / "Package.appxmanifest",
    WINDOWS / "src" / "FoundersOffice.App" / "packages.lock.json",
    WINDOWS / "tests" / "FoundersOffice.Core.Tests" / "FoundersOffice.Core.Tests.csproj",
    WINDOWS / "tests" / "FoundersOffice.Core.Tests" / "packages.lock.json",
]

missing = [str(path.relative_to(ROOT)) for path in required_files if not path.is_file()]
if missing:
    fail("missing required files: " + ", ".join(missing))

for xml_path in WINDOWS.rglob("*.xml"):
    ET.parse(xml_path)
for xml_path in WINDOWS.rglob("*.xaml"):
    ET.parse(xml_path)
for xml_path in WINDOWS.rglob("*.props"):
    ET.parse(xml_path)
for xml_path in WINDOWS.rglob("*.csproj"):
    ET.parse(xml_path)
ET.parse(WINDOWS / "FoundersOffice.Windows.slnx")

global_json = json.loads((WINDOWS / "global.json").read_text(encoding="utf-8"))
if global_json.get("sdk", {}).get("version") != "10.0.400":
    fail("global.json must pin the reviewed .NET SDK")

app_project_path = WINDOWS / "src" / "FoundersOffice.App" / "FoundersOffice.App.csproj"
app_project = ET.parse(app_project_path).getroot()
properties = {
    element.tag: (element.text or "").strip()
    for group in app_project.findall("PropertyGroup")
    for element in group
}
expected_properties = {
    "TargetFramework": "net10.0-windows10.0.26100.0",
    "TargetPlatformMinVersion": "10.0.22621.0",
    "UseWinUI": "true",
    "WindowsPackageType": "MSIX",
    "AppxPackageSigningEnabled": "false",
}
for name, expected in expected_properties.items():
    if properties.get(name) != expected:
        fail(f"{name} must be {expected}")

for project_path in WINDOWS.rglob("*.csproj"):
    project = ET.parse(project_path).getroot()
    for package in project.findall(".//PackageReference"):
        if "Version" in package.attrib or package.find("Version") is not None:
            fail(f"package version must be centralized: {project_path.relative_to(ROOT)}")

manifest_path = WINDOWS / "src" / "FoundersOffice.App" / "Package.appxmanifest"
manifest = ET.parse(manifest_path).getroot()
namespaces = {
    "foundation": "http://schemas.microsoft.com/appx/manifest/foundation/windows10",
    "desktop": "http://schemas.microsoft.com/appx/manifest/desktop/windows10",
}
family = manifest.find(".//foundation:TargetDeviceFamily", namespaces)
if family is None or family.attrib.get("MinVersion") != "10.0.22621.0":
    fail("MSIX manifest must enforce the Windows 11 beta baseline")
startup = manifest.find(".//desktop:StartupTask", namespaces)
if startup is None or startup.attrib.get("Enabled") != "false":
    fail("launch at startup must remain opt-in")

for lock_path in WINDOWS.rglob("packages.lock.json"):
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    if lock.get("version") != 2 or not lock.get("dependencies"):
        fail(f"invalid package lock: {lock_path.relative_to(ROOT)}")

source_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(WINDOWS.rglob("*.cs"))
)
for forbidden in ("Console.WriteLine", "Debug.WriteLine", "client_secret", "service_role"):
    if forbidden.lower() in source_text.lower():
        fail(f"forbidden diagnostic or credential marker found: {forbidden}")

if not (ROOT / "contracts" / "v1" / "openapi.json").is_file():
    fail("shared v1 contract is missing")

print("Windows scaffold validation passed.")
