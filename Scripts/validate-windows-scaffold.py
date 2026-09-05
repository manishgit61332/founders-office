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
    WINDOWS / "Configuration" / "ProductAuth.example.json",
    WINDOWS / "docs" / "public-configuration-and-sync-acceptance.md",
    WINDOWS / "tools" / "FoundersOffice.Acceptance" / "FoundersOffice.Acceptance.csproj",
    WINDOWS / "tools" / "FoundersOffice.Acceptance" / "packages.lock.json",
    WINDOWS / "Distribution" / "Install-Development.ps1",
    WINDOWS / "Distribution" / "README-DEVELOPMENT.md",
    WINDOWS / "Scripts" / "New-DevelopmentBundle.ps1",
    WINDOWS / "Scripts" / "test_verify_development_bundle.py",
    WINDOWS / "Scripts" / "verify-development-bundle.py",
    WINDOWS / "src" / "FoundersOffice.Core" / "FoundersOffice.Core.csproj",
    WINDOWS / "src" / "FoundersOffice.Core" / "Auth" / "ProductAuthentication.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "Auth" / "ProductSessionBroker.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "Auth" / "SupabaseProductAuthClient.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "Auth" / "WindowsProductConfiguration.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "Sync" / "SupabaseV1SyncTransport.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "Sync" / "WorkspaceSyncCoordinator.cs",
    WINDOWS / "src" / "FoundersOffice.Core" / "packages.lock.json",
    WINDOWS / "src" / "FoundersOffice.App" / "FoundersOffice.App.csproj",
    WINDOWS / "src" / "FoundersOffice.App" / "Package.appxmanifest",
    WINDOWS / "src" / "FoundersOffice.App" / "Platform" / "WindowsCredentialSessionStore.cs",
    WINDOWS / "src" / "FoundersOffice.App" / "packages.lock.json",
    WINDOWS / "tests" / "FoundersOffice.Core.Tests" / "FoundersOffice.Core.Tests.csproj",
    WINDOWS / "tests" / "FoundersOffice.Core.Tests" / "packages.lock.json",
]

missing = [str(path.relative_to(ROOT)) for path in required_files if not path.is_file()]
if missing:
    fail("missing required files: " + ", ".join(missing))

if "ProductAuth.local.json" not in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines():
    fail("local product-auth configuration must remain ignored")

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
startup_extension = manifest.find(".//desktop:Extension[@Category='windows.startupTask']", namespaces)
if startup_extension is None or startup_extension.attrib.get("Executable") != "FoundersOffice.App.exe":
    fail("startup extension must name the packaged executable explicitly")

for lock_path in WINDOWS.rglob("packages.lock.json"):
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    if lock.get("version") != 2 or not lock.get("dependencies"):
        fail(f"invalid package lock: {lock_path.relative_to(ROOT)}")

source_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(WINDOWS.rglob("*.cs"))
)
for forbidden in ("Console.WriteLine", "Debug.WriteLine", "client_secret"):
    if forbidden.lower() in source_text.lower():
        fail(f"forbidden diagnostic or credential marker found: {forbidden}")

main_window_source = (
    WINDOWS / "src" / "FoundersOffice.App" / "MainWindow.xaml.cs"
).read_text(encoding="utf-8")
if "MicaKind" in main_window_source:
    fail("MainWindow must not use the unavailable projected MicaKind API")
if "SystemBackdrop = new MicaBackdrop();" not in main_window_source:
    fail("MainWindow must install the supported WinUI Mica backdrop")
if "MainWindow : Window, IDisposable" not in main_window_source:
    fail("MainWindow must own its native resources through IDisposable")
if "readonly SqliteWorkspaceRepository _repository" not in main_window_source:
    fail("MainWindow must keep its concrete local repository ownership explicit")
main_window_xaml = (WINDOWS / "src" / "FoundersOffice.App" / "MainWindow.xaml").read_text(encoding="utf-8")
if "WINDOWS DEVELOPMENT" not in main_window_xaml:
    fail("the unfinished Windows package must remain visibly labeled as development")
for compact_boundary in ("CompactSurface", "CompactExpandButton_Click", "NormalModeButton_Click"):
    if compact_boundary not in main_window_xaml + main_window_source:
        fail(f"Windows compact/normal surface boundary is missing: {compact_boundary}")

repository_source = (
    WINDOWS / "src" / "FoundersOffice.Core" / "Repository" / "SqliteWorkspaceRepository.cs"
).read_text(encoding="utf-8")
for credential_column in ("access_token", "refresh_token", "provider_token"):
    if credential_column in repository_source.lower():
        fail(f"SQLite repository must not contain credential material: {credential_column}")

auth_source = (
    WINDOWS / "src" / "FoundersOffice.Core" / "Auth" / "ProductAuthentication.cs"
).read_text(encoding="utf-8")
transport_source = (
    WINDOWS / "src" / "FoundersOffice.Core" / "Sync" / "SupabaseV1SyncTransport.cs"
).read_text(encoding="utf-8")
credential_store_source = (
    WINDOWS / "src" / "FoundersOffice.App" / "Platform" / "WindowsCredentialSessionStore.cs"
).read_text(encoding="utf-8")
if "founders-office" not in auth_source or "founders-office-dev" not in auth_source:
    fail("product auth must keep the reviewed callback-scheme allowlist")
if "sb_secret_" not in transport_source or "service_role" not in transport_source:
    fail("public Supabase configuration must reject secret and service-role keys")
if "PasswordVault" not in credential_store_source:
    fail("durable Windows product sessions must use Credential Locker")

bundle_readme = " ".join(
    (WINDOWS / "Distribution" / "README-DEVELOPMENT.md").read_text(encoding="utf-8").split()
)
for required_boundary in (
    "not a production beta",
    "self-signed development certificate",
    "Sync",
):
    if required_boundary not in bundle_readme:
        fail(f"development bundle disclosure is missing: {required_boundary}")

bundle_script = (WINDOWS / "Scripts" / "New-DevelopmentBundle.ps1").read_text(encoding="utf-8")
if "KeyExportPolicy NonExportable" not in bundle_script:
    fail("development signing private key must remain non-exportable")
if "KeyUsage DigitalSignature" not in bundle_script:
    fail("development signing certificate must be restricted to digital signatures")
if '"2.5.29.19={text}"' not in bundle_script:
    fail("development signing certificate must be an end-entity certificate")
if '"-p:DebugType=None"' not in bundle_script or '"-p:DebugSymbols=false"' not in bundle_script:
    fail("development package must omit debug paths and symbols")
if r'Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)"' not in bundle_script:
    fail("development signing certificate must be removed from the build runner")

app_source = (
    WINDOWS / "src" / "FoundersOffice.App" / "App.xaml.cs"
).read_text(encoding="utf-8")
if "App : Application, IDisposable" not in app_source:
    fail("App must close the disposable MainWindow through an explicit lifetime")
if "_window.Closed += MainWindow_Closed;" not in app_source:
    fail("App must bind its cleanup to the WinUI window lifetime")

if not (ROOT / "contracts" / "v1" / "openapi.json").is_file():
    fail("shared v1 contract is missing")

print("Windows scaffold validation passed.")
