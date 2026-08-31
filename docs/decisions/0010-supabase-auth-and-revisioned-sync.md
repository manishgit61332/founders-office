# ADR 0010: Supabase Auth and revisioned cross-platform sync

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
the operation ID as a deterministic writer tie-break.

`profiles.display_name` is optional, bounded, and set from reviewed onboarding
input. It is neither inferred silently from an identity provider nor used as a
tenancy key. Account and workspace UUIDs remain opaque. Connector grants and
additional Google accounts use independent connector-account IDs and credentials.

## Consequences

- All supported platforms can implement the same language-neutral contract.
- Disjoint offline edits converge while true same-field conflicts remain visible.
- A compromised client JWT cannot bypass owner tenancy through direct writes.
- Export and exact-confirmation erasure are part of the first backend boundary.
- Production OAuth and deployment remain blocked until credentials, domains,
  redirect URIs, recovery, deletion, storage, monitoring, and legal review exist.

## Privacy and security

No email address, provider display name, access token, refresh token, service-role
key, or OAuth secret is stored in these contracts or durable product records.
Activity metadata is bounded and content-free. Assets store metadata and an owned
storage path; binary storage policies must be approved separately before upload is
enabled. Product sessions belong in platform secure storage.

## Migration and rollback

An authenticated customer must explicitly claim one local or CloudKit workspace.
Keep the source readable until checksums and record counts verify the import, then
make Supabase the sole writer. Do not run CloudKit and Supabase as permanent peers.
During a failed cutover, stop Supabase writes and restore the original local or
CloudKit workspace; never merge two authorities without a reviewed migration.

Disabling Google or Apple auth does not revoke connector grants automatically, and
disconnecting a connector does not remove product identity. Account erasure must
remove the owned workspace and separately revoke connector mappings.

## Related work

- [Separate product identity from connector authorization](0007-primary-auth-and-connector-authorization.md)
- [Platform sequence](../product/PLATFORM_SEQUENCE.md)
- [Supabase contract setup](../product/SUPABASE_LOCAL_SETUP.md)
- [Versioned sync contract](../../contracts/v1/README.md)
