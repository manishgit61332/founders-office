# Founder’s Office for Windows

This directory contains a testable **development build**, not a production or
friend beta. It proves the native Windows shell and local data boundaries while
the integration branch freezes production identity and sync.

## What runs today

- C# + WinUI 3 Windows 11 shell with Mica, a compact top-center view, an
  expanded workspace, and a normal resizable-window fallback;
- notification-area icon with left-click show/hide, a native Open/Hide + Exit
  menu, and recovery after Explorer restarts;
- local Move creation and editing with title, description, priority, and an
  optional deadline;
- active Moves, completion history, reopen, and confirmed soft deletion;
- local SQLite workspace under the signed-in Windows user’s local app-data;
- atomic Move + outbox transactions for offline-first sync preparation;
- strict hand-mapped HTTPS adapters for the existing `contracts/v1` bootstrap,
  push, and pull RPCs;
- Google PKCE and durable-session boundaries that keep access tokens in memory,
  reserve refresh-session persistence for Windows Credential Locker, and reject
  secret/service-role configuration;
- explicit claim-versus-attach provisioning, account isolation, push/rebase/pull,
  conflict quarantine, and a synthetic Mac-to-Windows fixture;
- a CI-produced x64 MSIX bundle signed with an ephemeral development certificate,
  with startup disabled by default and explicit non-production labeling;
- platform-neutral tests for repository, outbox, identity, transport, contract,
  cross-device fixtures, and placement rules.

It does **not** yet enable live Google/Apple product sign-in or remote sync.
Developers can validate reviewed public beta configuration in an ignored local file.
That file does not register the Windows callback or enable native browser activation.
Development bundles exclude it. A data-bearing workspace cannot attach until the reviewed
export-and-replace flow exists. The build also does not provide Calendar connectors,
production-trusted signing, automatic updates, recovery for deleted Moves, or a
public package identity. The interface and downloadable bundle label this state
honestly.

## Architecture

```text
FoundersOffice.App (WinUI 3 / AppWindow / tray / Credential Locker)
       │
       ▼
FoundersOffice.Core (Moves / Google PKCE / session broker / v1 RPC adapter)
       │
       ▼
SQLite workspace + operation outbox (never credentials)
       │
       ▼ configuration-gated; disabled in this build
Supabase Auth + HTTPS RPC contract v1
```

Windows consumes `contracts/v1`; this worktree must not change those schemas or
Supabase migrations. Contract proposals go to the integration branch first.

## Windows development setup

Use a Windows 11 machine, build 22621 or later.

1. Install Visual Studio with **.NET desktop development** and the WinUI/Windows
   App SDK components, or install the .NET SDK declared in `global.json` plus
   the Windows 11 SDK.
2. Open PowerShell in `Apps\Windows`.
3. Run:

   ```powershell
   dotnet restore .\FoundersOffice.Windows.slnx --locked-mode
   dotnet test .\tests\FoundersOffice.Core.Tests\FoundersOffice.Core.Tests.csproj -c Release --no-restore
   dotnet build .\src\FoundersOffice.App\FoundersOffice.App.csproj -c Release --no-restore -p:Platform=x64
   ```

4. Run `FoundersOffice.App` from Visual Studio. Use the notification-area icon
   to hide/show the compact view. Expand it for the full workspace, press Escape
   to collapse it, or choose the normal resizable window. Right-click for the
   native menu. Closing the surface hides it; **Exit** stops the process.

NuGet is restricted to `nuget.org`, versions are centrally pinned, and lock
files are committed. Do not place OAuth files, signing certificates, tokens, or
real workspace databases inside the repository.

For offline configuration checks and the separate live acceptance gates, see
[Windows public configuration and sync acceptance](docs/public-configuration-and-sync-acceptance.md).

## Downloadable development bundle

Every successful run of `.github/workflows/windows.yml` publishes
`FoundersOffice-Windows-x64-DEVELOPMENT` for 30 days. The artifact contains a
hash-verified ZIP with the MSIX, its public development certificate, dependency
packages when required, install script, build provenance, and test instructions.

The workflow creates a non-exportable signing key only inside the Windows runner,
removes it after packaging, verifies the archive allow-list and nested MSIX, and
rejects credentials, runtime data, caches, debug symbols, or development-machine
paths. The certificate is self-signed and short-lived. This is development
transport integrity, not production release signing.

## Windows-only verification still required

Before calling this a Windows alpha:

- compile and launch on physical Windows 11 x64;
- verify Mica, focus, keyboard, Narrator, 100–200% scaling, multiple displays,
  taskbar edge changes, compact/expanded/normal transitions, sleep/wake, and
  high-contrast mode;
- prove tray show/hide and explicit Exit across repeated launches;
- prove startup remains off until the user opts in;
- install the development-signed MSIX on both test laptops, then create, edit,
  relaunch, complete, reopen, and delete Moves without data loss;
- freeze the public package identity and repeat packaging with a production
  certificate on a clean second laptop;
- register the approved Windows callback and connect the public Supabase values
  only after account isolation, revoked sessions, offline convergence, explicit
  export-and-replace attachment, export, and erase pass the shared release gate.

Remote Desktop is useful for coding but not final motion/window-placement QA.
Run those checks while physically viewing the Windows display.
