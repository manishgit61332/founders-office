# ADR 0026: Native Windows shell and shared-contract boundary

- Status: Accepted
- Date: 2026-09-02

## Context

Founder’s Office is an OS-integrated, frequently opened focus surface rather
than a web dashboard. The Windows client needs a notification-area entry point,
reliable top-edge placement, native accessibility, startup consent, secure
credential storage, low idle cost, and signed MSIX distribution. The existing
Mac client is native Swift, so adopting Electron on Windows would not create a
single desktop codebase. It would add a Chromium/Node runtime while leaving
windowing, signing, startup, and platform integration as Windows-specific work.

Parallel development must also avoid creating a Windows-only data protocol.
The checked-in `contracts/v1` OpenAPI, schemas, and fixtures remain the only
cross-platform wire authority.

## Decision

The Windows client uses C#, WinUI 3, and the Windows App SDK. It presents a
Windows-native notification-area app and compact, always-on-top surface placed
within the active display work area; it does not imitate MacBook notch hardware.
The supported first-beta baseline is Windows 11 (build 22621 or later).

The client has three boundaries:

1. `FoundersOffice.Core` contains platform-neutral Move models, strict v1 JSON
   adapters, top-edge placement math, and the offline repository interface.
2. `SqliteWorkspaceRepository` owns local canonical Windows data and atomically
   records each local mutation with a bounded outbox operation.
3. `FoundersOffice.App` owns WinUI, AppWindow, notification-area, startup, and
   later Windows Credential Locker integration.

The development package identity is disposable. A public identity, publisher,
certificate, and update channel must be frozen before any external beta. The
Windows worktree may consume the shared v1 contract but may not modify it.

## Consequences

- Windows receives native Mica, keyboard/accessibility behavior, AppWindow
  control, system startup, and MSIX packaging without an embedded browser.
- The Windows UI is a separate shell, while domain and sync semantics remain
  testable against the language-neutral fixtures.
- Building XAML and exercising tray/window behavior requires Windows. The
  platform-neutral repository and adapter tests can run on macOS and CI.
- Product auth, live Supabase transport, Calendar connectors, signed packaging,
  and updates remain later gated milestones; the shell must not imply they work.

## Privacy and security

SQLite contains Moves and must remain under the current Windows user’s private
local application-data directory. OAuth sessions and connector tokens are
excluded from SQLite and will use Windows Credential Locker. Diagnostics expose
only stable error codes—never Move text, calendar titles, provider responses,
paths, tokens, or identifiers. Startup is disabled by default and user-enabled.

## Migration and rollback

The new code does not change the shared schema, Supabase migrations, or any Mac
runtime store. It can be removed by deleting `Apps/Windows` and its independent
CI workflow. No customer migration exists until a signed Windows beta ships.

## Related work

- `Apps/Windows/README.md`
- `Apps/Windows/src/FoundersOffice.Core`
- `Apps/Windows/src/FoundersOffice.App`
- `contracts/v1`
- `docs/product/PLATFORM_SEQUENCE.md`
