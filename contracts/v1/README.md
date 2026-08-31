# Founder’s Office sync contract v1

This directory is the language-neutral boundary between native clients and the
approved Supabase cross-platform authority. Supabase Auth owns product sessions
for Google and Apple identities; Postgres and the versioned RPCs own workspace
tenancy, revisioned sync, export, and erasure. The repository contains no
deployment credentials and does not enable a live Supabase project.

- `openapi.json` describes the HTTPS/Supabase RPC surface.
- `schemas/records.schema.json` defines durable workspace records.
- `schemas/sync.schema.json` defines identity, operation, cursor, conflict,
  activity, bootstrap, push, pull, export, and erase envelopes.

Contract changes are additive within v1. A breaking field, enum, tenancy, or
conflict-semantics change requires a new versioned directory. JSON object keys
use lower camel case on the wire. UUIDs are opaque; email addresses and display
names are never tenancy keys.

`p_display_name` is required by the server when an account bootstraps for the
first time and optional thereafter. Its value must come from reviewed onboarding,
not directly from provider metadata. It uses the shared v1 display-name contract:
NFC, Unicode whitespace/newline trimming, at most 80 Unicode scalars and 320 UTF-8
bytes, at least one letter/number/symbol, and no controls, line/paragraph
separators, bidi controls, or BOM. The server returns `startingCursor: 0` because
a newly registered device has not acknowledged any workspace change yet.

V1 has exactly one owner and one workspace per Founder account. A different
`p_local_workspace_id` is rejected when the account already owns a workspace;
the server never silently uploads or replaces another local workspace.

Every mutation carries a bounded, unique `changedFields` mask and one timestamp
in `fieldClocks` for each named field. The server applies only those fields, so
disjoint offline edits can merge without replacing a newer lifecycle change.
If the server changed any incoming field after `baseRevision`, it returns an
`overlappingChanges` conflict for review even when the incoming clock is later.
For equal-base safety, an older clock loses and equal clocks use the operation ID
as a stable tie-break. `occurredAt` and every field clock must be finite and no
more than five minutes ahead of the server, limiting bad-device clock dominance.
Wire timestamps use canonical RFC 3339 with a timezone and at most six fractional
digits; PostgreSQL's broader timestamp input aliases are rejected.
An operation ID is immutable: an exact replay returns the durable prior result,
while reuse with different JSON content fails the entire push. Only a successful
`pull_changes` page advances a device cursor. Bootstrap and push update presence
but never acknowledge changes the device has not pulled.
Every change's `changedFields` must exist in the returned record's `fieldClocks`.
A conflict's `conflictingFields` contains only server-clocked fields; it is
nonempty for overlapping/clock-lost conflicts and can be empty for a missing
record or a pure revision mismatch.

Primary-goal numbers are exact, nonnegative base-10 `numeric(30,8)` values.
Clients must use decimal types and must not route these values through binary
floating-point.

Workspace export includes database rows plus an exact private-object manifest.
`assetTransfer.state` is `notRequired`, `requiresPrivateStorageAdapter`, or
`verified`. `verified` is valid only when a privileged external adapter records
proof for the exact current manifest. Erasure fails closed until every listed
private object has matching deletion proof. Its durable, account-scoped receipt
makes retries idempotent and prevents a stale local snapshot from recreating the
erased workspace ID. Authenticated clients cannot write transfer proofs. After
the Auth identity is deleted, its account link is removed from the receipt but an
opaque workspace-ID tombstone remains. The Auth deletion trigger refuses to run
while an owned workspace still exists.

Account deletion is ordered: export, exact-manifest private-byte deletion proof,
`erase_workspace`, connector revocation, then the approved Supabase Auth Admin
deletion. Deleting a profile directly is not supported and must not be exposed.

The authoritative membership relation is `workspace_members`. The read-only
`members` view exists only for compatibility with early v1 drafts.

Product identity is separate from connector authorization. One Google or Apple
identity opens Founder’s Office; additional Google, Gmail, Drive, Calendar, or
other resource accounts are independent connector grants with their own opaque
connector account IDs. They never become workspace tenancy keys. Clients must
keep Supabase session material in an approved secure store. Implementations must
never log tokens or record payloads.

Activity events expose only typed IDs, kind, and time. Their `metadata` object is
an exact empty allow-list in v1; adding metadata requires a reviewed contract
version rather than a blacklist of sensitive keys.
