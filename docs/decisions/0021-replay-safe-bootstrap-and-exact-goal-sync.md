# 0021 — Replay-safe bootstrap and exact primary-goal sync

- Status: Accepted
- Date: 2026-09-01
- Supersedes: the bootstrap and primary-goal limitations in ADR 0020
- Extends: ADR 0015, ADR 0017, and ADR 0018

## Context

The first live-sync implementation rebuilt its canonical bootstrap from the
current local revision each time. A crash after the server accepted only part of
that bootstrap, or a local edit while the request was in flight, could make the
client generate a different retry plan. It also sent a base-revision-zero
workspace-name operation immediately after `bootstrap_workspace` had created
that singleton, which would conflict with the record returned by the RPC.

Primary-goal sync was intentionally blocked until the local model adopted exact
`GoalDecimal` values. That migration is now complete. Finally, an accepted older
local operation can appear in the pull feed after a newer edit of the same field
has been committed locally. Applying that feed value blindly would hide the
newer pending edit even though its outbox operation remained durable.

## Decision

1. SQLite schema 4 pins one immutable, credential-free canonical bootstrap plan
   to the bound account, workspace, and device before network delivery. Every
   retry and relaunch uses the same operation IDs, payloads, clocks, local
   revision, and digest until exact server acknowledgement commits.
2. Bootstrap acknowledgement no longer requires the current local revision to
   equal the pinned revision. It deletes only outbox work committed at or before
   the pinned revision, so local edits made while bootstrap is in flight remain
   pending. Receipt creation, entity baselines, bounded outbox deletion,
   bootstrap completion, and attempt removal share one SQLite transaction.
3. `bootstrap_workspace` is the only create path for the workspace singleton.
   The canonical operation list never includes a base-zero workspace mutation.
   The validated workspace record returned by the RPC seeds its authoritative
   positive revision and name field clock. A later local rename therefore uses
   that positive base revision.
4. Primary goals map `GoalDecimal.decimalValue` directly to
   `SyncJSONValue.number`. Current and target values remain nullable, deadlines
   use `PlanningDate` date-only conversion, and tombstones use the reviewed
   `deletedAt` delete operation. No sync path converts a goal through `Double`.
5. Pull validates that workspace and Appearance singleton entity IDs equal the
   response workspace ID. Before applying a remote changed field, SQLite compares
   its server clock with all still-pending local clocks for that entity and
   field. An equal-or-newer pending local field remains visible until accepted or
   conflicted, while the remote revision, dedupe ID, and cursor still commit.
6. Any current image asset or valid legacy resolved photo filename blocks
   bootstrap until the private asset-transfer path is implemented.

## Consequences

- Partial acceptance is idempotently replayable after a crash or relaunch.
- A local edit made during bootstrap is retained and delivered after bootstrap.
- Workspace renames no longer conflict merely because bootstrap created the
  singleton first.
- Exact eight-place and maximum `numeric(30,8)` goal values converge through
  bootstrap, push, pull, SQLite persistence, and relaunch without binary
  floating-point conversion.
- Pull cannot visually roll a newer pending same-field edit back to an older
  accepted value.
- Ordinary profile operations and all image transfers remain fail closed.

## Privacy and security

The pinned plan contains the same bounded entity payloads already approved for
sync, but no token, email, provider credential, endpoint, or file path. It stays
inside the protected workspace database. Singleton-ID checks prevent a validly
shaped record for another entity from crossing the response workspace boundary.
Legacy photo metadata cannot silently bypass the disabled private-asset gate.

## Migration and rollback

Schema 3 to 4 creates the bootstrap-attempt table transactionally and leaves all
canonical state and outbox rows untouched. A pre-attempt database creates and
pins its first plan on demand. Newer schemas remain downgrade-refused. Rollback
requires a reviewed export or database backup; manually lowering SQLite
`user_version` is prohibited.

## Verification

Tests cover exact eight-place and maximum goal values, nullable goal values,
date-only deadlines, local and remote tombstones, relaunch without outbox echo,
workspace baseline revision seeding, a later rename, partial acceptance plus
local mutation and relaunch, invalid singleton IDs, legacy photo blocking, and
an older accepted pull value racing a newer pending local value.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0017 — Bounded local entity operation outbox](0017-bounded-local-entity-outbox.md)
- [0018 — Exact bounded primary-goal decimals](0018-exact-primary-goal-decimals.md)
- [0020 — Fail-closed local live-sync engine](0020-fail-closed-live-sync-engine.md)
