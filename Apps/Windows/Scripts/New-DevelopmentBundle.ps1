[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^0\.1\.[0-9]{1,5}\.0$")]
    [string]$PackageVersion,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-fA-F]{40}$")]
    [string]$CommitSha,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$")]
    [string]$RunUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$windowsRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $windowsRoot "src\FoundersOffice.App\FoundersOffice.App.csproj"
$distributionRoot = Join-Path $windowsRoot "Distribution"
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$stagingRoot = Join-Path $outputRoot "FoundersOffice-Windows-x64-DEVELOPMENT"
$packageOutput = Join-Path $outputRoot "package"
$archivePath = Join-Path $outputRoot "FoundersOffice-Windows-x64-DEVELOPMENT.zip"

if (Test-Path -LiteralPath $outputRoot) {
    throw "Development bundle output already exists. Use a new empty output directory."
}

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $packageOutput -Force | Out-Null

$certificate = $null
try {
    $certificate = New-SelfSignedCertificate `
        -Type Custom `
        -Subject "CN=FounderOfficeDevelopment" `
        -FriendlyName "Founder's Office ephemeral development signer" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddDays(30) `
        -TextExtension @(
            "2.5.29.37={text}1.3.6.1.5.5.7.3.3",
            "2.5.29.19={text}"
        )

    $buildArguments = @(
        "build",
        $projectPath,
        "--configuration", "Release",
        "--no-restore",
        "-p:Platform=x64",
        "-p:AppxBundle=Never",
        "-p:UapAppxPackageBuildMode=SideloadOnly",
        "-p:GenerateAppxPackageOnBuild=true",
        "-p:AppxPackageSigningEnabled=true",
        "-p:PackageCertificateThumbprint=$($certificate.Thumbprint)",
        "-p:AppxPackageVersion=$PackageVersion",
        "-p:DebugType=None",
        "-p:DebugSymbols=false",
        "-p:AppxPackageDir=$packageOutput\"
    )
    & dotnet @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "The development MSIX build failed."
    }

    $applicationPackages = @(
        Get-ChildItem -LiteralPath $packageOutput -Recurse -Filter "*.msix" -File |
            Where-Object { $_.FullName -notmatch "[\\/]Dependencies[\\/]" }
    )
    if ($applicationPackages.Count -ne 1) {
        throw "Expected exactly one application MSIX from the x64 development build."
    }

    $packagePath = Join-Path $stagingRoot "FoundersOffice-Windows-x64-DEVELOPMENT.msix"
    Copy-Item -LiteralPath $applicationPackages[0].FullName -Destination $packagePath
    $packageSignature = Get-AuthenticodeSignature -LiteralPath $packagePath
    if ($null -eq $packageSignature.SignerCertificate `
        -or $packageSignature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
        throw "The development MSIX signature does not match the ephemeral signing certificate."
    }
    Export-Certificate `
        -Cert $certificate `
        -FilePath (Join-Path $stagingRoot "FounderOfficeDevelopment.cer") `
        -Type CERT | Out-Null

    $dependencyDirectories = @(
        Get-ChildItem -LiteralPath $packageOutput -Recurse -Directory |
            Where-Object { $_.Name -eq "Dependencies" }
    )
    if ($dependencyDirectories.Count -gt 1) {
        throw "The development package produced ambiguous dependency directories."
    }
    if ($dependencyDirectories.Count -eq 1) {
        Copy-Item `
            -LiteralPath $dependencyDirectories[0].FullName `
            -Destination (Join-Path $stagingRoot "Dependencies") `
            -Recurse
    }

    Copy-Item `
        -LiteralPath (Join-Path $distributionRoot "Install-Development.ps1") `
        -Destination $stagingRoot
    Copy-Item `
        -LiteralPath (Join-Path $distributionRoot "README-DEVELOPMENT.md") `
        -Destination $stagingRoot

    $buildInfo = @(
        "Founder's Office for Windows — DEVELOPMENT",
        "Architecture: x64",
        "Package version: $PackageVersion",
        "Commit: $($CommitSha.ToLowerInvariant())",
        "Workflow: $RunUrl",
        "Signing: ephemeral self-signed development certificate; not production trusted"
    )
    Set-Content `
        -LiteralPath (Join-Path $stagingRoot "BUILD-INFO.txt") `
        -Value $buildInfo `
        -Encoding utf8NoBOM

    $hashLines = @(
        Get-ChildItem -LiteralPath $stagingRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = [System.IO.Path]::GetRelativePath($stagingRoot, $_.FullName).Replace("\", "/")
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$hash  $relativePath"
            }
    )
    Set-Content `
        -LiteralPath (Join-Path $stagingRoot "SHA256SUMS.txt") `
        -Value $hashLines `
        -Encoding ascii

    Compress-Archive -LiteralPath $stagingRoot -DestinationPath $archivePath -CompressionLevel Optimal
    Write-Output $archivePath
} finally {
    if ($null -ne $certificate) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -Force
    }
}
