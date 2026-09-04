# ADR 0027: Windows product session and v1 sync boundary

- Status: Accepted
- Date: 2026-09-05
- Extends: ADR 0015, ADR 0022, ADR 0023, and ADR 0026

## Context

The Windows client needs the same Founder’s Office product identity and workspace
as Mac and Android without treating a Google Calendar grant as product sign-in,
inventing a Windows-only protocol, or placing credentials beside local Moves.
It must also preserve offline edits and distinguish claiming a local workspace
from attaching the workspace already owned by an account.

The production Supabase project values and a registered Windows OAuth callback
are not present in this repository. A development adapter must therefore be
testable without implying that live identity or sync is enabled.

## Decision

1. Windows consumes the existing `contracts/v1` bootstrap, push, and pull RPCs
   through a bounded HTTPS adapter. It does not change shared schemas.
2. Google product sign-in uses Supabase Auth PKCE and only the reviewed
   `founders-office://auth/callback` or development callback shape. The client
   accepts only HTTPS project origins and publishable or legacy anonymous keys;
   secret, service-role, placeholder, and arbitrary key material fail closed.
3. Access tokens exist only in memory. The refresh token plus opaque account ID
   and provider enum use Windows Credential Locker. A signed-in state requires
   an exact read-back, and sign-out requires verified removal.
4. A first unbound sync requires an explicit provisioning choice. Claim sends
   the stable local workspace UUID. Attach sends no local UUID, and is allowed
   automatically only for a repository-proven empty workspace. Data-bearing
   attachment remains blocked until the existing immutable export-and-replace
   workflow is implemented.
5. Local operations push one at a time. Each accepted revision rebases later
   edits to the same Move before they are sent. Pull applies the record, inbound
   operation ID, and cursor atomically. Unsupported entity types and pending
   same-entity local edits stop before cursor advancement.
6. A bounded synthetic fixture demonstrates a Mac-originated Move entering a
   fresh Windows workspace. No real account, token, workspace, or provider data
   is used by tests.

## Consequences

- Windows has a production-shaped identity and sync seam ready for public
  configuration without claiming that the development package is cloud-enabled.
- Restart can restore a product session without writing access tokens to SQLite.
- Account changes and workspace attachment cannot silently cross local tenancy.
- Windows currently synchronizes only Moves. Encountering another v1 entity
  fails closed until its native model and persistence are implemented.
- Conflict rows are quarantined for later review; a complete Windows conflict
  resolution interface remains a release gate.

## Privacy and security

Provider credentials never enter Founder’s Office. Google product identity is
separate from Calendar and other connector grants. Requests and errors expose
stable codes only; response bodies and tokens are never logged. Public Supabase
configuration is not secret, but its absence keeps networking disabled. The
SQLite workspace contains no access token, refresh token, or connector token.

## Migration and rollback

The local SQLite schema moves to version 2 by adding a singleton sync binding and
an inbound-operation table. Existing Move and outbox rows remain unchanged. The
adapter is not constructed without reviewed public configuration, so rollback is
local-only operation with the existing data intact. Removing the Credential
Locker item signs the device out without deleting its workspace.

## Verification

Platform-neutral tests cover callback and public-key rejection, exact PKCE and
RPC requests, durable session restore and identity mismatch, claim-versus-attach,
account isolation, offline operation rebasing, conflict quarantine, cursor
atomicity, unsupported entities, and the Mac-to-Windows fixture. Native browser,
Credential Locker, window, tray, and physical-display behavior still require a
Windows 11 acceptance run.

## Related work

- [Supabase Auth and revisioned sync](0015-supabase-auth-and-revisioned-sync.md)
- [Explicit existing-workspace provisioning](0022-explicit-existing-workspace-provisioning.md)
- [Durable sync runtime state and conflict review](0023-durable-sync-runtime-state-and-conflict-review.md)
- [Native Windows shell](0026-native-windows-shell.md)
- [Windows development notes](../../Apps/Windows/README.md)
