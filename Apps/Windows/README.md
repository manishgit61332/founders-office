# Founder’s Office for Windows

This directory contains the first **developer milestone**, not a distributable
friend beta. It proves the native Windows shell and local data boundaries while
the integration branch freezes production identity and sync.

## What runs today

- C# + WinUI 3 Windows 11 shell with Mica and a compact top-edge surface;
- notification-area icon that shows or hides the surface;
- user-entered Move title and optional description;
- local SQLite workspace under the signed-in Windows user’s local app-data;
- atomic Move + outbox transactions for offline-first sync preparation;
- strict hand-mapped readers for the existing `contracts/v1` fixtures;
- MSIX project/manifest structure with startup disabled by default;
- platform-neutral tests for repository, outbox, contract, and placement rules.

It does **not** yet provide live Google/Apple product sign-in, Supabase transport,
Calendar connectors, signed MSIX installation, automatic updates, or a public
package identity. The interface labels local state honestly.

## Architecture

```text
FoundersOffice.App (WinUI 3 / AppWindow / tray / future Credential Locker)
       │
       ▼
FoundersOffice.Core (Moves / repository seam / v1 fixture adapter)
       │
       ▼
SQLite workspace + operation outbox
       │
       ▼ later, after the shared contract gate
Supabase HTTPS RPC contract v1
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
   to hide/show it. Closing the surface hides it; **Exit** stops the process.

NuGet is restricted to `nuget.org`, versions are centrally pinned, and lock
files are committed. Do not place OAuth files, signing certificates, tokens, or
real workspace databases inside the repository.

## Windows-only verification still required

Before calling this a Windows alpha:

- compile and launch on physical Windows 11 x64;
- verify Mica, focus, keyboard, Narrator, 100–200% scaling, multiple displays,
  taskbar edge changes, sleep/wake, and high-contrast mode;
- prove tray show/hide and explicit Exit across repeated launches;
- prove startup remains off until the user opts in;
- create, relaunch, complete, and delete Moves without data loss;
- build an unsigned internal MSIX, then freeze the public package identity and
  repeat with a trusted certificate on a clean second laptop;
- connect the approved Supabase transport only after account isolation, revoked
  sessions, offline convergence, export, and erase pass the shared release gate.

Remote Desktop is useful for coding but not final motion/window-placement QA.
Run those checks while physically viewing the Windows display.
