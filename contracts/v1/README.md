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
not directly from provider metadata.

Every mutation carries a bounded, unique `changedFields` mask and one timestamp
in `fieldClocks` for each named field. The server applies only those fields, so
disjoint offline edits can merge without replacing a newer lifecycle change.
If the server changed any incoming field after `baseRevision`, it returns an
`overlappingChanges` conflict for review even when the incoming clock is later.
For equal-base safety, an older clock loses and equal clocks use the operation ID
as a stable tie-break. `occurredAt` and every field clock must be finite and no
more than five minutes ahead of the server, limiting bad-device clock dominance.

The authoritative membership relation is `workspace_members`. The read-only
`members` view exists only for compatibility with early v1 drafts.

Product identity is separate from connector authorization. One Google or Apple
identity opens Founder’s Office; additional Google, Gmail, Drive, Calendar, or
other resource accounts are independent connector grants with their own opaque
connector account IDs. They never become workspace tenancy keys. Clients must
keep Supabase session material in an approved secure store. Implementations must
never log tokens or record payloads.
