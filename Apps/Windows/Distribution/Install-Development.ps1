[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DevelopmentBundleRelativePath {
    param([string]$BundleRoot, [string]$FilePath)
    $prefix = [System.IO.Path]::GetFullPath($BundleRoot).TrimEnd([char[]]"\/") + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($FilePath)
    if (-not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "An installable file is outside the extracted bundle."
    }
    return $fullPath.Substring($prefix.Length)
}

if ([Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Machine") -ne "AMD64") {
    throw "This development bundle requires a Windows 11 x64 laptop."
}

$bundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$certificatePath = Join-Path $bundleRoot "FounderOfficeDevelopment.cer"
$checksumPath = Join-Path $bundleRoot "SHA256SUMS.txt"
$packages = @(Get-ChildItem -LiteralPath $bundleRoot -Filter "*.msix" -File)

if ($packages.Count -ne 1) {
    throw "Expected exactly one Founder's Office development MSIX."
}

if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
    throw "The development certificate is missing. Download and extract the complete bundle again."
}

if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw "The checksum manifest is missing. Download and extract the complete bundle again."
}

$expectedHashes = @{}
foreach ($line in Get-Content -LiteralPath $checksumPath) {
    if ($line -notmatch "^([0-9a-fA-F]{64})  (.+)$") {
        throw "The checksum manifest is malformed."
    }

    $relativeName = $Matches[2].Replace("/", "\")
    if ($expectedHashes.ContainsKey($relativeName)) {
        throw "The checksum manifest contains a duplicate entry."
    }
    $expectedHashes[$relativeName] = $Matches[1].ToUpperInvariant()
}

$filesToVerify = @($packages[0], Get-Item -LiteralPath $certificatePath)
$dependencyRoot = Join-Path $bundleRoot "Dependencies"
if (Test-Path -LiteralPath $dependencyRoot -PathType Container) {
    $filesToVerify += @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File)
}

foreach ($file in $filesToVerify) {
    $relativePath = Get-DevelopmentBundleRelativePath -BundleRoot $bundleRoot -FilePath $file.FullName
    if (-not $expectedHashes.ContainsKey($relativePath)) {
        throw "The checksum manifest does not cover every installable file."
    }

    $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHashes[$relativePath]) {
        throw "A bundled file failed its integrity check. Download the bundle again."
    }
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
if ($certificate.Subject -ne "CN=FounderOfficeDevelopment") {
    throw "The bundled certificate does not match the development package identity."
}

$signature = Get-AuthenticodeSignature -LiteralPath $packages[0].FullName
if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
    throw "The MSIX signature does not match the bundled development certificate."
}

$trustedCertificatePath = "Cert:\LocalMachine\TrustedPeople\$($certificate.Thumbprint)"
if (-not (Test-Path -LiteralPath $trustedCertificatePath)) {
    throw "The exact development certificate needs administrator-approved Local Computer > Trusted People trust first. Follow README-DEVELOPMENT.md, then rerun as your normal Windows user. This installer does not change certificate trust."
}

$dependencies = @()
if (Test-Path -LiteralPath $dependencyRoot -PathType Container) {
    foreach ($dependencyArchitecture in @("x64", "neutral")) {
        $architectureRoot = Join-Path $dependencyRoot $dependencyArchitecture
        if (Test-Path -LiteralPath $architectureRoot -PathType Container) {
            $dependencies += @(
                Get-ChildItem -LiteralPath $architectureRoot -Recurse -File |
                    Where-Object { $_.Extension -in ".appx", ".msix" } |
                    ForEach-Object { $_.FullName }
            )
        }
    }
}

if ($dependencies.Count -gt 0) {
    Add-AppxPackage -Path $packages[0].FullName -DependencyPath $dependencies
} else {
    Add-AppxPackage -Path $packages[0].FullName
}

Write-Host "Founder's Office DEVELOPMENT was installed. Open it from Start."
