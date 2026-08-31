# 0023 — Durable sync runtime state and reviewed conflicts

- Status: Accepted
- Date: 2026-09-01

## Context

The first live-sync coordinator persisted `syncing` before each run, but then
derived retry attempt one from that transient value. Repeated failures therefore
did not grow their delay across runs or relaunches. Cancellation and manual
failures could also leave the durable status claiming that work was still in
progress. Cursor or bootstrap changes detected after a network await were
treated as terminal blocks, so the trigger which caused the state change could
be lost.

Conflict persistence stored the server record but deleted the corresponding
local outbox operation. That destroyed the only exact copy of the value the user
had attempted to save and made **Keep Mine** impossible. Clearing a conflict by
re-exposing the old operation was also insufficient: its old field clocks would
deterministically lose again. Finally, inbound commits had a separate stream
which the live Mac session did not consume, and subscribing after reading a
snapshot left a missed-update window.

Some sync proof tables also had no explicit retention boundary. Deleting remote
operation IDs without a server-authenticated replay horizon would weaken
deduplication, while deleting unresolved conflicts or quarantined records would
destroy evidence required for recovery.

## Decision

1. The coordinator preserves `retryAttempt` and `lastSuccessAt` while a run is
   active. Retry delays grow exponentially and persist across relaunch. A
   durable `retryScheduled` state is written only when the started coordinator
   owns the corresponding timer. A standalone manual failure remains idle with
   its failure streak and returns a blocked result. Cancellation normalizes any
   stale `syncing` state without discarding the streak or last success.
2. Bootstrap-revision and pull-cursor changes are nonterminal state changes.
   Manual and automatic drains retry them within the existing hard consecutive
   run budget. A real event arriving during the final await remains pending for
   one fresh bounded drain; internal continuation requests cannot spin forever.
3. The repository exposes one replay-latest, origin-tagged event stream. Each
   subscription atomically registers and receives the latest durable snapshot
   as `initial`; later changes are `local` or `remote`. The Mac session consumes
   all origins and advances only to a newer revision. The coordinator wakes only
   for `local`, so remote commits update the UI exactly once without an outbox
   echo.
4. A conflict keeps its exact v2 local operation in the existing outbox. The row
   is excluded from deliverable batches while the conflict exists, but remains
   visible to the pending-field-clock protection seam used by remote pull.
   Conflict state remains `conflictReviewRequired` after otherwise clean runs and
   across relaunch until every conflict is explicitly resolved.
5. **Use Latest** applies the reviewed server fields, retires the exact local
   operation, and deletes the conflict in one SQLite transaction. It fails
   closed when the server evidence cannot cover every remotely meaningful field
   that would otherwise be discarded.
6. **Keep Mine** rejects a stale review when a later overlapping local operation
   or accepted local acknowledgement exists. Otherwise it reapplies only the
   exact fields from the retained payload, advances the workspace revision, and
   atomically creates a new operation and idempotency receipt. The new operation
   has a fresh identity and the review instant for all chosen field clocks; the
   losing operation and conflict are then retired. A review instant which does
   not exceed the known local and conflicting server clocks is rejected.
7. Partial server records merge their clocks with the authenticated clocks
   already stored for the entity. Omitted disjoint clocks are retained and an
   overlapping older clock is rejected, so either conflict choice cannot
   regress comparison evidence.
8. Acknowledgement and canonical-bootstrap receipts have bounded newest-first
   retention. A pruned acknowledgement replay fails closed. Applied remote
   operation IDs are not pruned without a versioned server replay horizon; the
   repository enforces a hard count limit before changing canonical state.
   Unresolved conflicts, their retained outbox operations, and quarantined
   malformed operations are never removed by retention. Reaching the exact
   acknowledgement window remains serviceable; only evidence that cannot be
   pruned below the bound is reported as a blocking overflow.

## Consequences

- Retry state now describes a real execution path and grows 1, 2, 4, and so on
  instead of resetting on each `syncing` transition.
- A customer can review a conflict after a pull or relaunch without losing the
  exact local value, and **Keep Mine** produces an operation capable of winning
  a new server comparison.
- An old conflict cannot overwrite a later local decision.
- Remote changes become visible in the open Mac UI without triggering another
  outbound operation.
- Applied-operation proof can reach a fail-closed capacity gate. Continuing
  beyond that gate requires a separately versioned server replay-horizon
  protocol, not local deletion.

## Privacy and security impact

No credentials, endpoints, response bodies, or customer text are added to
diagnostics. Conflict payloads remain inside the private workspace database and
are retained only because they are canonical recovery evidence. Resolution is
explicit; the app never chooses **Keep Mine** or **Use Latest** automatically.

## Migration and rollback

This decision itself adds no table and does not change SQLite `user_version`.
The integrated build retains schema 4 and the `sync_bootstrap_attempt` journal
introduced by ADR 0021; the runtime changes use the existing sync tables
additively. A rollback can ignore the unified event stream, but must not delete
outbox rows referenced by unresolved conflicts. Builds predating reviewed
conflict resolution will continue to see the durable conflict and remain fail
closed.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0017 — Bounded local entity operation outbox](0017-bounded-local-entity-outbox.md)
- [0020 — Fail-closed local live-sync engine](0020-fail-closed-live-sync-engine.md)
- [0021 — Replay-safe bootstrap and exact primary-goal sync](0021-replay-safe-bootstrap-and-exact-goal-sync.md)
