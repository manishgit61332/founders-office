# ADR 0015: Supabase Auth and revisioned cross-platform sync

- Status: Accepted
- Date: 2026-08-31
- Supersedes: ADR 0007 only where it deferred the managed identity provider

## Context

Founder's Office needs one durable account and workspace across Mac, iPhone,
Windows, and Android. The Apple beta can use local state and CloudKit, but CloudKit
cannot be the identity and sync authority for non-Apple clients. Offline devices
also need an idempotent protocol that preserves disjoint edits without silently
choosing a winner for concurrent edits to the same field.

Product sign-in and optional connector access are different security boundaries.
A founder may sign in with one Google identity while connecting several unrelated
Google accounts for Calendar, Drive, or Gmail.

## Decision

Supabase is the approved backend authority. Supabase Auth owns product sessions
with Google and Apple as the v1 identity providers. Postgres owns profiles,
single-owner workspaces and membership, product records, revision history, device
cursors, and user-visible activity events.
Milestones are first-class records because important dates/countdowns in the
canonical personalization document must survive bootstrap, pull, and export;
they are not hidden inside Appearance JSON.

V1 enforces one workspace per owner with a database uniqueness constraint. A
local workspace is never auto-claimed over an existing owned workspace.

Clients cross five versioned boundaries: `bootstrap_workspace`,
`push_operations`, `pull_changes`, `export_workspace`, and `erase_workspace`.
Authenticated clients have owner-scoped reads but no direct mutation grants. The
security-definer RPCs use an empty search path, establish ownership themselves,
and are the only write boundary. Every table uses forced row-level security.

Each mutation has an immutable operation ID, base revision, bounded unique
`changedFields`, a matching field-clock map, a payload containing exactly those
fields, and an occurrence time. Replayed operation IDs are idempotent. A stale
base may merge only when no accepted revision since that base changed an incoming
field. A stale same-field edit returns `overlappingChanges` for customer review,
even if its local clock is later. Field clocks and operation occurrence times more
than five minutes ahead of the server are rejected. Equal-base/equal-clock ties use
the operation ID as a deterministic writer tie-break. Every pull change names only
fields present in its record's field-clock map. Conflict responses include a
`conflictingFields` mask containing only server-clocked fields; overlapping and
clock-lost conflicts cannot return an empty mask.

The server keeps the complete accepted/conflict result beside the canonical
operation envelope. Exact replay is idempotent; the same operation ID with
different content is rejected. Only pull acknowledges a cursor. Primary-goal
numbers use exact `numeric(30,8)`, activity metadata is exactly empty, and display
names use the same NFC, whitespace, visible-scalar, forbidden-scalar, 80-scalar,
and 320-byte rules as the product-auth client.

Database export and private-byte export are separate but joined by an exact asset
manifest. Asset mutation remains disabled until a privileged storage adapter can
prove export and deletion for the current manifest. Workspace erasure refuses to
delete database rows without deletion proof, then retains an account-scoped
tombstone and receipt so the operation is retryable and the workspace ID cannot
be resurrected by a stale device. After Auth identity deletion, the tombstone
drops its account link but remains as an opaque globally unique workspace-ID deny
record. It has no foreign-key cascade back to the deleted profile.

`profiles.display_name` is optional, bounded, and set from reviewed onboarding
input. It is neither inferred silently from an identity provider nor used as a
tenancy key. Account and workspace UUIDs remain opaque. Connector grants and
additional Google accounts use independent connector-account IDs and credentials.

## Consequences

- All supported platforms can implement the same language-neutral contract.
- Disjoint offline edits converge while true same-field conflicts remain visible.
- A compromised client JWT cannot bypass owner tenancy through direct writes.
- Export and exact-confirmation erasure are part of the first backend boundary.
- Auth identity deletion is guarded: it fails while an owned workspace exists,
  so database export/deletion proof and `erase_workspace` must finish first.
- A storage adapter and immediate-session-revocation decision remain production
  gates rather than being simulated in the SQL contract.
- Production OAuth and deployment remain blocked until credentials, domains,
  redirect URIs, recovery, deletion, storage, monitoring, and legal review exist.

## Privacy and security

No email address, provider display name, access token, refresh token, service-role
key, or OAuth secret is stored in these contracts or durable product records.
Activity metadata is bounded and content-free. Assets store metadata and an owned
storage path; authenticated clients cannot record transfer proof. Binary storage
policies and the privileged transfer adapter must be approved and integration-
tested before upload is enabled. Product sessions belong in platform secure storage.

The local Supabase configuration bounds access-token lifetime to 3,600 seconds,
but an already-issued token may remain usable during that window after refresh-
token revocation. Production release remains blocked until that residual access
window is explicitly accepted or an official Supabase-supported immediate-
revocation mechanism is implemented and tested. No unsupported session-epoch
semantics are assumed here.

## Migration and rollback

An authenticated customer must explicitly claim one local or CloudKit workspace.
Keep the source readable until checksums and record counts verify the import, then
make Supabase the sole writer. Do not run CloudKit and Supabase as permanent peers.
During a failed cutover, stop Supabase writes and restore the original local or
CloudKit workspace; never merge two authorities without a reviewed migration.

Disabling Google or Apple auth does not revoke connector grants automatically, and
disconnecting a connector does not remove product identity. Account erasure must
export requested data, prove deletion for the exact private-object manifest,
call `erase_workspace`, revoke connector mappings, and only then delete the Auth
identity through the approved Supabase Admin path. The database trigger rejects
the Auth deletion if that order is bypassed. Direct profile deletion is not an
account-deletion API.

## Related work

- [Separate product identity from connector authorization](0007-primary-auth-and-connector-authorization.md)
- [Platform sequence](../product/PLATFORM_SEQUENCE.md)
- [Supabase contract setup](../product/SUPABASE_LOCAL_SETUP.md)
- [Versioned sync contract](../../contracts/v1/README.md)
