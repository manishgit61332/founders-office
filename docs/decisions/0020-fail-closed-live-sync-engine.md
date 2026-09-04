# 0020 — Fail-closed local live-sync engine

- Status: Accepted
- Date: 2026-09-01
- Extends: ADR 0015 and ADR 0017

## Context

The v1 Supabase contract and local v2 entity outbox existed without a production
client bridge. Connecting them naively could erase disjoint edits, delete outbox
rows without server proof, advance a pull cursor before records committed, invent
missing field clocks, or create an unbounded retry loop. Access tokens must also
remain outside the workspace database.

This decision implements the core repository, mapping, transport, and coordinator
boundaries. It does not enable cloud sync in the customer app.

## Decision

1. SQLite schema 3 stores one explicit local/remote workspace binding, account
   and device identity, bootstrap state, pull cursor, server entity revisions and
   field clocks, conflict evidence, operation acknowledgements, applied-operation
   dedupe IDs, bootstrap receipts, and quarantined malformed operations. Newer
   schemas remain downgrade-refused.
2. A v2 outbox row is deliverable only when `fieldClocks.keys` exactly equals its
   changed-field mask. Schema-2 rows that fail this invariant are preserved in a
   quarantine table and block sync; the client never fabricates clocks.
3. The reviewed adapter maps every supported local field to the frozen v1 wire
   field, including `dueAt` to date-only `dueOn` and local `waiting` to remote
   `blocked`. Profile edits outside reviewed bootstrap, primary goals on this
   branch base, and all asset mutations fail closed.
4. Canonical bootstrap acknowledgement requires an opaque receipt bound to the
   authenticated account, local and remote workspace, device, exact local
   revision and snapshot digest, server session/profile/workspace response,
   accepted operation result set, and server cursors. Receipt creation and exact
   outbox deletion are one transaction. Bootstrap and push never advance the
   pull cursor.
5. Pull validates tenancy, cursor continuity, response bounds, operation IDs,
   records, revisions, and clocks before one SQLite transaction performs
   field-scoped entity merge, server-state update, dedupe insertion, and cursor
   advance. Any error rolls back the entire page and creates no outbound echo.
6. Conflicts and acknowledgements must match the exact pending operation identity
   and reviewed wire clock map. Exact replays are idempotent; altered evidence is
   rejected. Resolving conflicts is separate product work.
7. The Supabase adapter calls only the five allow-listed HTTPS RPC paths derived
   from the exact configured origin. It bounds requests and streaming responses,
   rejects redirects, unexpected response URLs, non-JSON content, unknown nested
   response fields, missing or duplicate results, and malformed session identity.
   It sends a bearer token and publishable client key but never logs either or
   response content.
8. The coordinator is event-driven. It runs only after an explicit binding and
   matching authenticated session, pushes before pulling, coalesces concurrent
   manual and automatic requests, and has hard batch, page, and consecutive-run
   budgets. A page-limit continuation cannot spin; a real event arriving during
   the final awaited run is preserved as a fresh bounded drain. Retry uses one
   bounded exponential-backoff timer with jitter and no polling.

## Consequences

- Local-only remains the default and unchanged when no binding exists.
- Duplicate delivery and process restart are safe at the local boundary.
- Disjoint inbound/local field edits converge without stale whole-component
  clobbering.
- Malformed responses, revoked sessions, future schemas, cursor discontinuities,
  clock mismatches, and interrupted transactions stop without cursor skip or
  outbound echo.
- The engine is a tested integration seam, not a release claim. No Account & Sync
  UI or customer runtime constructs this transport until production identity,
  endpoint configuration, backend integration, RLS, revocation, observability,
  and migration gates pass.

## Intentionally disabled capabilities

- **Primary goal:** this branch base predates the canonical `GoalDecimal` model,
  so delivery and pull fail closed without conversion. Integration already owns
  that exact-decimal migration; after merging this engine, it must map
  `GoalDecimal.decimalValue` losslessly to `SyncJSONValue.number` and add exact
  round-trip tests before enabling primary-goal sync.
- **Profile:** the reviewed name may cross `bootstrap_workspace`; ordinary
  profile outbox operations remain blocked until the frozen contract defines an
  update operation. A pending profile edit is never silently discarded.
- **Assets:** upload, download, replacement, and deletion remain disabled until
  private Storage export and erasure are proved. Replacing image A with B must
  not lose A's tombstone.
- **Conflict resolution:** evidence persists for review, but the client does not
  choose a winner or mark a Move complete automatically.

## Privacy and security

Tokens are requested at call time from the product-auth boundary and never enter
SQLite, operation payloads, status strings, or diagnostics. Transport errors are
content-free. Responses are byte-bounded before decode. Cross-account and
cross-workspace identifiers fail before canonical mutation. Asset bytes remain
local and never enter this engine.

## Migration and rollback

Schema 2 to 3 runs transactionally. Malformed pending v2 rows are quarantined,
not deleted. A crash during bootstrap acknowledgement or pull leaves both the
canonical state and cursor at their previous values. Rollback requires restoring
a reviewed pre-schema-3 database or supported export; manually lowering
`user_version` is prohibited.

## Verification

The suite covers exact clock masks, migration quarantine and relaunch, identity
and workspace isolation, duplicate delivery, disjoint convergence, bootstrap
proof replay and mismatch, conflict evidence replay, pull rollback/no echo,
cursor persistence, revoked auth, strict nested JSON, endpoint and HTTP failures,
request/response bounds, cancellation before network start, hostile pagination,
real-event preservation at a run cap, and concurrent run coalescing.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0017 — Bounded local entity operation outbox](0017-bounded-local-entity-outbox.md)
- [Supabase contract setup](../product/SUPABASE_LOCAL_SETUP.md)
