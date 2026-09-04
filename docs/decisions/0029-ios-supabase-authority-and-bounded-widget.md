# ADR 0029 — iPhone uses Supabase authority and a bounded WidgetKit projection

- Status: Accepted
- Date: 2026-09-05
- Supersedes: the iOS scaffold's provisional CloudKit runtime arrangement

## Context

The original iPhone scaffold placed a CloudKit writer next to a shared
cross-platform Supabase contract. That could produce two cloud authorities for
one workspace. A WidgetKit extension also needs a small, privacy-sensitive data
source, not a second database client or an entitlement to perform work.

## Decision

1. The iPhone application uses `SQLiteWorkspaceRepository` for its local
   authority and the existing product-auth, provisioning, transport, and
   coordinator boundaries for Supabase device sync. It does not construct a
   CloudKit runtime or request CloudKit/APNs capability.
2. Product sign-in is Google first, using the configured PKCE callback. The
   equivalent Apple sign-in path stays disabled until explicitly configured and
   joins the same product-account model. Product credentials never become
   calendar or connector grants.
3. Sign-in is separate from workspace provisioning. A data-bearing unbound
   workspace may only be claimed through an explicit customer choice; a fresh
   device may explicitly attach to the existing account workspace. A durable
   opaque binding prevents cross-account reuse after sign-out.
4. The widget reads one atomic App Group projection containing at most one Move,
   one local commitment, and one goal. It cannot access SQLite, sessions,
   connector grants, files, agents, or mutation APIs. It deep-links to the app
   and marks customer content privacy-sensitive.
5. Private vision-image transfer remains unavailable. Existing metadata is
   preserved and blocks unsafe bootstrap; remote-only CloudKit data requires a
   separate verified migration utility. Neither condition may be bypassed by a
   client fallback.

## Consequences

- iPhone edits retain the entity-scoped outbox, replay-safe retry, remote
  cursor, and conflict semantics already used by the cross-platform contract.
- The app remains useful without auth or live public configuration.
- Widget installation on a physical device requires App Group provisioning;
  the extension fails closed to a content-free state when the group is absent.
- This does not establish TestFlight, App Store, simulator, physical-device,
  RLS, session-revocation, or live-sync acceptance evidence.

## Privacy and security impact

Account, workspace, and device identifiers remain opaque. Sessions are stored
in device-local Keychain storage. Calendar permission and event content remain
on the iPhone and are neither sync authority nor connector credentials. The
widget projection is cleared until secure-session restoration completes and on
sign-out; it contains no token, endpoint, outbox, account, workspace, or full
workspace data.

## Migration and rollback

Local JSON stays read-only migration input to SQLite. A rollback may disable
Supabase and remain local-only, but it must not reactivate CloudKit as a second
writer. Remote-only legacy workspaces need an explicit source/destination
verified migration before normal device sync.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0022 — Explicit existing-workspace provisioning](0022-explicit-existing-workspace-provisioning.md)
- [0023 — Durable sync runtime state and reviewed conflicts](0023-durable-sync-runtime-state-and-conflict-review.md)
- [0027 — Mac customer builds use Supabase as the sole cloud authority](0027-mac-supabase-only-customer-authority.md)
