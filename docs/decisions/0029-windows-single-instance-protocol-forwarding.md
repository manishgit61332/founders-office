# ADR 0029: Windows single-instance protocol forwarding

- Status: Accepted
- Date: 2026-09-05
- Extends: ADR 0027 and ADR 0028

## Context

Windows can launch a second process for a protocol link or another Start-menu request.
A callback must reach the process holding its pending verifier without creating another workspace writer.
Local activation testing must not depend on registered live OAuth or alter Calendar connections.

## Decision

1. Register only the `founders-office-dev` protocol in the development MSIX.
2. Select one development app instance before creating a window, repository, or tray icon.
3. Forward secondary activations through Windows App SDK instance routing, with a ten-second wait limit.
4. Exit the secondary instance after successful or failed forwarding. Never take over its workspace on failure.
5. Dispatch redirected callbacks to the owning UI thread, retaining at most one pending redirected request.
6. Route bounded, exact callbacks only to an explicitly supplied, same-process session broker.
7. Keep that broker absent from the shipped native app until the separate live OAuth gates pass.
8. Show product account, Move sync, and Windows Calendar states separately.

App construction initializes theme resources only, so the supported `OnLaunched` ownership check precedes all workspace work.
The callback router cannot construct a pending flow, restore its verifier, provision a workspace, or access Calendar.
Errors use fixed outcomes. Activation URLs, credentials, and exception contents never enter diagnostics.

## Consequences

Physical laptops can test cold-start, warm-start, duplicate-launch, and malformed-link behavior without cloud credentials.
The callback manifest does not certify Supabase allowlist approval or exclusive custom-scheme ownership.
Actual Google sign-in still requires Windows execution and user interaction.
Live sync still requires convergence on the exact same synthetic workspace as Mac.

## Verification

Synthetic tests cover missing brokers, foreign callbacks, process-local verifier ownership, concurrent delivery, failed exchanges, and replay.
Windows CI verifies native compilation and packaging. The bundled one-time checklist records the remaining physical checks.
Microsoft documents the chosen
[OnLaunched pattern](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/guides/applifecycle#single-instancing-in-applicationonlaunched).
