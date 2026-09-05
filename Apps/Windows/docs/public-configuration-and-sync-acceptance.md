# Windows public configuration and sync acceptance

## Current boundary

The Windows app remains local-only. Configuration validation does not enable sign-in or sync.
The MSIX registers only `founders-office-dev` and forwards activations to one workspace-owning instance.
Forwarding times out after ten seconds. Failure never opens a second workspace writer.
The native account controller contains browser, session, callback, and workspace-selection code.
Its compiled registration approval remains absent. It cannot construct a live broker, restore a session, or sync.
All protocol links therefore leave product sign-in unavailable in this build.
Native forwarding still requires physical Windows acceptance. Synthetic routing tests do not prove operating-system activation.
Main integration owns beta-project callback registration and approval.
Mac callback registration does not prove Windows registration.

## Public configuration

Use `Apps/Windows/Configuration/ProductAuth.local.json` for reviewed, public beta values.
This exact basename is ignored and forbidden in tracked files and development bundles.
Copy only the approved project endpoint and publishable key from the reviewed source.
Do not copy OAuth provider credentials, service-role keys, session tokens, or Mac callback settings.

For an installed MSIX, select **Open setup folder** in the expanded workspace.
Copy the same Windows file into that package-private folder, then select **Reload setup**.
The app uses `ApplicationData.Current.LocalFolder`, not a guessed or hard-coded Windows user path.
Public configuration never enters the installer. A setup file alone cannot enable Google login.

Native service construction also requires a separately reviewed, compiled configuration fingerprint.
It binds the exact HTTPS project origin, publishable key, and development callback.
Main integration must confirm the exact Supabase allowlist entry before supplying that approval.
The fingerprint records that review. It does not probe or independently prove the backend allowlist.
Runtime files, environment variables, and interface toggles cannot supply approval.
Changing the project or public key requires another review and a fresh, configuration-scoped session.

The strict schema has exactly four fields:

```json
{
  "schemaVersion": 1,
  "supabaseURL": "https://project.supabase.co",
  "publishableKey": "sb_publishable_fixture",
  "callbackURL": "founders-office-dev://auth/callback"
}
```

These are synthetic example values. They do not identify a working beta project.
The parser requires bounded UTF-8 JSON, an HTTPS origin, and a public client-key shape.
It rejects unknown fields, duplicate keys, URL credentials, endpoint paths, queries, fragments, and alternate callbacks.
It also rejects linked configuration files. It reports fixed error codes without file paths or input values.
No configuration field can certify registration, consent, or successful sync.

From `Apps/Windows`, run the offline check:

```powershell
dotnet restore .\tools\FoundersOffice.Acceptance\FoundersOffice.Acceptance.csproj --locked-mode
dotnet run --project .\tools\FoundersOffice.Acceptance\FoundersOffice.Acceptance.csproj -c Release --no-restore -- --configuration .\Configuration\ProductAuth.local.json
```

The check parses configuration and prepares a transient Google PKCE request.
Its HTTP handler refuses network access. It does not launch a browser or retain the verifier.
Success reports valid configuration and PKCE preparation, with registration, sign-in, and convergence explicitly unverified.
Use `ProductAuth.example.json` for synthetic CI checks. Never place the local file in CI or a release artifact.

## Callback registration request

Register this exact development redirect in the approved beta project:

```text
founders-office-dev://auth/callback
```

Do not register a wildcard or infer approval from the Mac callback.
The callback is the final app redirect, not Google's provider callback to Supabase.
The production package identity and production callback require separate review.

Google product sign-in uses the system browser and Supabase's S256 PKCE flow.
The authorization request includes `provider=google`, `redirect_to`, `code_challenge`, and `code_challenge_method=s256`.
The token exchange sends only `auth_code` and `code_verifier` to `/auth/v1/token?grant_type=pkce`.
The exchange client refuses redirects and bounds response sizes.

Accept a callback only for the pending, unexpired flow on the same device.
Match the configured scheme, host, port, and exact path before exchanging the code.
Reject path case changes, trailing slashes, encoded aliases, dot segments, credentials, fragments, and duplicate codes.
The session broker consumes the pending flow once. A second launch cannot reconstruct its verifier from a URL.
Native activation must forward to the owning process without logging the URL or exchanging it in another process.
PKCE does not prove exclusive custom-scheme ownership. Test interception and activation behavior on Windows before approval.

Keep access tokens and PKCE verifiers in memory.
Persist only the refresh session, opaque account ID, and provider in Windows Credential Locker.
Require durable read-back before showing a signed-in state.
Credential Locker entries use the development identity and reviewed configuration fingerprint as their resource scope.
Unscoped legacy entries are not migrated automatically.
Browser refusal, cancellation, shutdown, or the ten-minute deadline clears the pending attempt without deleting local Moves.
Restoring a session never starts a workspace claim, attachment, or Calendar connection.

## Synthetic acceptance sequence

Run these live checks only after callback approval and physical native-activation acceptance.
Use disposable test identities and a dedicated synthetic workspace. Do not upload a personal local workspace.
Keep any raw acceptance evidence outside tracked files and release bundles. Do not log credentials or callback URLs.

1. Record the exact tested Mac and Windows commits and artifact hashes.
2. Complete Google product sign-in on Mac and explicitly claim the synthetic workspace.
3. Record its opaque remote workspace ID privately as the comparison target.
4. Create a synthetic Move on Mac with a description, priority, and deadline.
5. On a fresh Windows workspace, complete Google sign-in with the same identity.
6. Explicitly attach the existing workspace. Verify its remote ID equals the Mac target.
7. Compare the Move ID, title, description, status, priority, deadline, and server revision on both devices.
8. Edit the Move offline on Windows. Relaunch offline and verify the edit remains intact.
9. Reconnect and sync. Verify the same Move converges on Mac, with no duplicate or lost edit.
10. Complete the synthetic Move on Mac. Verify Windows receives the same status and server revision.
11. Relaunch Windows and verify secure session restoration with the same account and workspace.
12. Test a different identity, provider refusal, expired callback, replay, and revoked refresh session.
13. Verify data-bearing attachment stops for review without altering local Moves or outbox records.
14. Verify conflicts and unsupported entities stop safely without advancing past unhandled changes.
15. Test sign-out and confirm the local workspace remains intact and secure session removal succeeds.

Synthetic adapter tests are not live proof. A browser sign-in alone is not convergence proof.
Do not claim live sync until both native clients converge on the exact same synthetic workspace.
Windows currently supports Move sync only. Other workspace entities and conflict review remain separate implementation gates.
The native interface shows the remote workspace ID for this private comparison.
If unsupported records stop a run, stop the test and report the step. Do not call that run converged.
Quarantined conflicts block subsequent runs and direct same-Move pull replacement, including after repository relaunch.

## Calendar boundary

Google product login does not grant Calendar access.
Mac uses EventKit to aggregate calendars configured through macOS Internet Accounts, including separate Google accounts.
Windows needs its own calendar source and consent flow. Product login must not imply a calendar connection.

## Native forwarding checks

Use the one-time checklist in the bundled `README-DEVELOPMENT.md` on each Windows laptop.
It needs no Supabase registration, Google account, cloud VM, or live configuration.
The development protocol is registered locally by MSIX installation, not by the offline configuration preflight.
One process owns the workspace. Secondary processes redirect activation, wait at most ten seconds, and exit.
Redirected requests reach the UI dispatcher. The app retains at most one pending redirected request during launch storms.
The callback router never reconstructs a verifier or restores a flow from another process.

This uses Microsoft's documented
[OnLaunched single-instance pattern](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/migrate-to-windows-app-sdk/guides/applifecycle#single-instancing-in-applicationonlaunched).
App construction initializes theme resources only. The app selects an owner before creating the window, repository, or tray icon.
