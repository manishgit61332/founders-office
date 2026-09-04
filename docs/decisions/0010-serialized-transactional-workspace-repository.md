# 0010 — Serialized transactional workspace repository

- Status: Accepted
- Date: 2026-08-31

## Context

Founder’s Office currently has multiple JSON writers and modification-date polling. A task edit, personalization edit, primary-goal edit, tombstone, and sync preparation can therefore succeed or fail independently even though customers experience them as one workspace. JSON files are also unable to provide a durable optimistic revision, exactly-once retry receipt, or atomic operation outbox.

The first repository slice must be safe to adopt before the current Mac stores are rewired. Existing workspace and Recovery files are customer data and cannot be deleted, rewritten, or treated as expendable migration inputs.

## Decision

1. The public local boundary is an actor-isolated `WorkspaceRepository` with `snapshot()`, `transact(expectedRevision:mutation:)`, and `changes()` semantics. The actor owns one SQLite connection and publishes a change only after its transaction commits.
2. Store the complete shared `FounderOfficeSnapshot` in one canonical SQLite state row. This gives Moves, tombstones, personalization, Appearance, milestones, and the primary goal one atomic revision without prematurely duplicating the evolving domain model into independently writable tables.
3. Start a workspace at revision zero. A content-changing transaction increments the revision exactly once; a no-op does not. A stale expected revision fails without writing a receipt, outbox entry, or partial state.
4. Assign one durable device-writer ID to each local database. An explicitly supplied workspace or writer identity must match on reopen. Identity mismatches fail closed.
5. Give every mutation an immutable operation ID and idempotency key. Store a request fingerprint and result revision in a durable receipt. An exact retry returns the prior result even after its outbox entry is acknowledged; reuse with different input is rejected.
6. Insert the canonical snapshot, receipt, and pending outbox operation in the same SQLite transaction. The outbox carries local entity metadata, changed-field names, field clocks, base and committed revisions, and a versioned snapshot payload. It is sync preparation, not the versioned HTTPS contract.
7. Mark the database with an application ID and `user_version`. Refuse to open a newer schema rather than attempting a downgrade. Migrations run under `BEGIN IMMEDIATE` and roll back as a unit.
8. Import legacy data only when both `openloops.json` and `personalization.json` exist, decode, and use supported schemas. Preserve their exact bytes and all Recovery contents. An incomplete, unreadable, or newer legacy workspace remains untouched and fails closed.
9. Generate JSON and Markdown projections only into a new export directory. Include an immutable manifest with the workspace revision, generation time, byte counts, and SHA-256 digests. Never overwrite an earlier export.
10. Open and migrate SQLite through a detached factory, then perform repository I/O on the repository actor rather than `MainActor`.

## Consequences

- Local mutation order, conflicts, retry behavior, and pending sync work are deterministic and testable.
- A whole-snapshot payload is intentionally less space-efficient than entity tables. It is the smallest safe compatibility step; later schema versions can normalize query-heavy entities without changing the public repository boundary.
- Idempotency receipts grow even after outbox acknowledgement. A future bounded compaction policy must retain enough history to cover every supported retry window before deleting any receipt.
- The `changes()` stream observes commits made through that repository actor. Cross-process delivery requires a separate notification mechanism; polling is not part of this boundary.
- This slice does not rewire the existing Mac or iOS stores. Until that reviewed integration lands, legacy JSON remains the running app’s canonical source. No code may introduce an additional SQLite writer outside `WorkspaceRepository`.
- The operation outbox does not define Supabase tables, RLS, merge behavior, or the public sync contract. Those remain separately versioned integration work.

## Privacy and security

- The database, outbox payloads, legacy imports, and exports contain customer content and remain private runtime data.
- Repository errors expose bounded operation names and SQLite result codes, never task titles, names, prompts, credentials, file paths, SQL text, or database messages.
- Legacy import digests verify what was read without logging or modifying source content.
- Exports require an explicit destination and never overwrite an existing directory.

## Migration and rollback

The initial migration is additive: create a new SQLite database next to, not over, the legacy files; verify both legacy documents; insert one revision-zero snapshot and import digests transactionally; then reopen and read the committed state. If any step fails, delete only the newly created database after explicit recovery review and continue using the untouched legacy files.

Before the app switches its canonical writer, rollback is simply omission of this repository integration. After the switch, rollback requires an explicit export from a sealed revision; an older app must never write over the SQLite workspace implicitly.

## Related work

- ADR 0001 — Dedicated private product repository
- ADR 0002 — Separate diagnostics, activity history, and analytics
- ADR 0006 — Composable, versioned appearance personalization
- ADR 0007 — Separate product identity from connector authorization
