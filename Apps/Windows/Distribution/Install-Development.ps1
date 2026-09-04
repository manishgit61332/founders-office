[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

    $expectedHashes[$Matches[2].Replace("/", "\")] = $Matches[1].ToUpperInvariant()
}

$filesToVerify = @($packages[0], Get-Item -LiteralPath $certificatePath)
$dependencyRoot = Join-Path $bundleRoot "Dependencies"
if (Test-Path -LiteralPath $dependencyRoot -PathType Container) {
    $filesToVerify += @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File)
}

foreach ($file in $filesToVerify) {
    $relativePath = [System.IO.Path]::GetRelativePath($bundleRoot, $file.FullName)
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

Write-Warning "This trusts a self-signed Founder's Office DEVELOPMENT certificate for the current user. It is not a production release certificate."
Import-Certificate -FilePath $certificatePath -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null

$dependencies = @()
if (Test-Path -LiteralPath $dependencyRoot -PathType Container) {
    $dependencies = @(
        Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File |
            Where-Object { $_.Extension -in ".appx", ".msix" } |
            ForEach-Object { $_.FullName }
    )
}

if ($dependencies.Count -gt 0) {
    Add-AppxPackage -Path $packages[0].FullName -DependencyPath $dependencies
} else {
    Add-AppxPackage -Path $packages[0].FullName
}

Write-Host "Founder's Office DEVELOPMENT was installed. Open it from Start."
