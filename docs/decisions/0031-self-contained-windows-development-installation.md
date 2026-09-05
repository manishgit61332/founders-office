# ADR 0031: Self-contained Windows development installation

- Status: Accepted
- Date: 2026-09-05
- Extends: ADR 0026 and ADR 0029

## Context

Physical laptop acceptance must not assume a developer workstation with an existing .NET runtime or PowerShell 7.
Artifact inspection found that the earlier bundle depended on an external .NET 10 runtime.
Its installer used a path API unavailable in Windows PowerShell 5.1 and selected unrelated dependency architectures.
Its build record also reported a version that did not change the actual MSIX manifest version.
The previous Current User certificate-trust instructions did not meet Windows' machine-level MSIX trust requirement.

## Decision

1. Set `SelfContained` explicitly and select a Windows runtime identifier independently of the build host.
2. Include the .NET runtime in the application MSIX and reject external framework requirements in its runtime configuration.
3. Bundle and install only x64 or neutral Windows App Runtime dependencies for the x64 development package.
4. Keep the installer compatible with Windows PowerShell 5.1 and validate its path helper in that host during CI.
5. Generate a versioned manifest outside tracked source and explicitly select it for packaging.
6. Compare the actual MSIX identity version with the exact build record before publishing the artifact.
7. Retain development-only signing, exact checksums, and all privacy boundaries.
8. Require explicit administrator-approved trust of the exact bundled public certificate in Local Computer → Trusted People. The installer only checks for that trust; it does not import certificates, request elevation, or weaken policy. Run app installation as the intended normal Windows user after that setup.

The Windows App Runtime remains an MSIX framework dependency supplied in the bundle.
The .NET runtime is application-local. These are separate dependencies.
Microsoft documents that modern
[runtime identifiers do not imply self-contained .NET deployment](https://learn.microsoft.com/en-us/dotnet/core/compatibility/sdk/8.0/runtimespecific-app-default).
Microsoft also requires [machine-level trust for the development MSIX certificate](https://learn.microsoft.com/en-us/windows/msix/msix-troubleshooting-guide).
This corrects the earlier bundle's Current User/no-administrator installation instructions without changing production trust policy.

## Verification

Archive fixtures reject missing runtimes, external framework requirements, wrong dependency architectures, and mismatched package versions.
Windows CI parses the installer and executes its path-boundary helper under PowerShell 5.1 without trusting or installing certificates.
The native package still requires installation and startup checks on physical Windows laptops.
Package completeness is not evidence of Google login, callback approval, or workspace convergence.
