# 0022 — Explicit existing-workspace provisioning

- Status: Accepted
- Date: 2026-09-01
- Extends: ADR 0015 and ADR 0020

## Context

The local database UUID and the remote personal-workspace UUID are not always
the same. A first Mac can claim its local UUID, but a second device starts with a
new local UUID and must discover the workspace already owned by the signed-in
account. The ordinary sync binding intentionally rejected that mismatch. Product
account sessions also do not—and must not—invent a workspace ID from provider
metadata.

Calling `bootstrap_workspace` with every new local UUID would make the backend's
one-workspace ownership rule reject a returning customer. Relaxing the binding
check alone would be worse: it could attach a remote identity while retaining and
later uploading unrelated local content.

## Decision

1. Provisioning is a separate, explicit one-shot boundary. Its disposition is
   either **claim this local workspace as new** or **attach the signed-in
   account's existing workspace**. Product sign-in cannot call either action by
   itself.
2. Claim sends the local UUID to `bootstrap_workspace`, requires the returned
   account, provider, device, and workspace UUID to match exactly, and then
   records the normal binding. It does not replace the local snapshot.
3. Attach discovers with `localWorkspaceID: nil`, validates the returned account,
   provider, and device against the token-free `ProductAccountSession`, and pulls
   the complete bounded change feed from cursor zero. The backend workspace UUID
   lives in `WorkspaceSyncBinding`; the local database UUID remains stable.
4. A repository-proven fresh device may authorize attachment without an export.
   Any customer-authored local content requires an explicit **export and
   replace** authorization and a new export destination. The immutable local
   export is committed before the SQLite replacement transaction begins.
5. The complete feed, workspace record, entity revisions, field clocks, operation
   IDs, cursor continuity, and tenancy are validated before replacement. One
   SQLite transaction replaces the canonical snapshot, removes old-authority
   outbox/receipt state, writes the remote binding, cursor, entity revisions, and
   applied-operation dedupe evidence, and marks bootstrap complete. Any failure
   rolls the transaction back without changing canonical data.
6. Existing local bindings for another account, provider, or device fail before
   network discovery. Remote/private image assets remain blocked because the
   current immutable JSON export does not prove preservation of their bytes.
7. The provisioning seam is test-only infrastructure for now. Account & Sync UI
   choices stay disabled until production RLS/RPC, identity, revocation, private
   asset, monitoring, and two-device acceptance gates pass.

## Consequences

- A returning customer can attach a fresh second device even though its local and
  remote workspace UUIDs differ.
- Signing in still cannot upload or destroy local data.
- A data-bearing device always has a durable pre-replacement export, and a failed
  export or interrupted transaction leaves the original authority untouched.
- Replaying already imported remote changes is prevented by the atomically stored
  cursor and applied-operation IDs.
- The backend's `bootstrap_workspace(nil, ...)` boundary still creates an empty
  workspace when the account owns none. That is safe only because attachment is
  explicit and data-bearing replacement requires export; a future contract may
  separate discovery from creation for clearer product copy.

## Privacy and security

The provisioner compares only opaque account, workspace, and device IDs plus the
approved identity-provider enum. It receives no email address and stores no
credential. Local exports contain private customer data and remain untracked
runtime artifacts. Errors and status values are content-free.

## Migration and rollback

No additional SQLite schema migration is added. The existing schema-4 binding, cursor,
revision, dedupe, receipt, and outbox tables are reused. Rollback before the
replacement transaction is a no-op; rollback after a successful explicit
replacement uses the immutable local export and the existing reviewed recovery
path, never an automatic merge of two authorities.

## Verification

Tests cover a different remote UUID on a second device, full and empty remote
feeds, claim-versus-attach request shape, mandatory pre-replacement export,
export interruption, remote account mismatch, an existing other local identity,
atomic cursor/revision establishment, and relaunch.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0020 — Fail-closed local live-sync engine](0020-fail-closed-live-sync-engine.md)
- [Mac Account & Sync](../product/MAC_ACCOUNT_AND_SYNC.md)
