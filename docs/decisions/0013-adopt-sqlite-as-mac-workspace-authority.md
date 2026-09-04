# ADR 0013 — Adopt SQLite as the Mac workspace authority

- Status: Accepted
- Date: 2026-08-31
- Supersedes: the temporary non-adoption consequence in ADR 0010

## Context

ADR 0010 introduced a transactional SQLite repository but deliberately left the running Mac stores on two independently written JSON documents. That transition state still allowed a Move edit, Appearance edit, CloudKit merge, or modification-date watcher to race with another writer. It also made a successful UI action appear durable before both workspace components shared one revision.

The legacy JSON pair and Recovery directory are customer data. Migration must not rewrite them, and an incomplete or unreadable pair must stop before a new canonical workspace is initialized.

## Decision

1. `founders-office.sqlite3` is the only canonical local writer used by the Mac app after migration.
2. Startup opens the repository asynchronously, imports the complete legacy JSON pair once, and preserves the source and Recovery bytes exactly. A partial or unreadable pair fails closed.
3. `OpenLoopStore` and `PersonalizationStore` are MainActor UI adapters. They do not read, write, or poll JSON. They submit component-scoped patches to the shared repository and observe its commit stream.
4. Component patches are applied to the latest snapshot inside the repository actor. This prevents rapid Move and personalization changes from replacing unrelated newer state while retaining the versioned public `transact(expectedRevision:mutation:)` interface.
5. Appearance saves include an Appearance revision precondition. Unrelated Move commits do not create a false conflict; a same-field change returns a reviewable conflict and leaves the draft intact.
6. The latest committed revision is projected asynchronously into an immutable JSON and Markdown directory under `Generated/revision-*`. Rapid commits may coalesce before projection. Generated cache retention is bounded to the newest two projected revisions; explicit exports remain immutable and unpruned. Legacy root JSON is never refreshed or treated as current state.
7. The Python workspace tool may read the newest generated projection. It refuses mutations when the SQLite workspace exists, so it cannot become a competing writer.
8. The legacy Mac CloudKit JSON bridge is removed. CloudKit data may be handled only by an explicit one-time migration; cross-device sync uses the separately reviewed sync contract and operation outbox.
9. SQLite, import, projection, identity, and image-file work run outside MainActor. UI adapters update published state only after returning to MainActor.

## Consequences

- Moves, tombstones, personalization, goals, Appearance, durable revision, device writer, idempotency receipts, and outbox entries now share one transaction authority on Mac.
- UI mutations are queued and surface failure; failed Appearance saves retain the preview and committed state separately.
- Generated JSON is compatible with export and inspection workflows but is intentionally read-only.
- Cross-process CLI mutation is deferred until it can call the repository contract rather than modifying a projection.
- Legacy CloudKit sync is unavailable after adoption. Product identity and Supabase sync must pass their own release gate before cross-device sync is advertised.

## Privacy and security

- The database, legacy inputs, generated projections, assets, and outbox remain private runtime data and are excluded from source control.
- Errors remain bounded and do not log Move titles, names, file paths, SQL, or payloads.
- Migration verifies the complete pair before creating canonical state and never deletes Recovery data.

## Migration and rollback

On first launch, the app creates SQLite next to the legacy pair, verifies and imports both documents, commits revision zero, and generates a revision projection. The exact legacy bytes remain available for explicit recovery.

Rollback is not an implicit downgrade. An older JSON-writing app must not run against a migrated workspace. Recovery requires an explicit immutable export and user-authorized replacement.

## Related work

- ADR 0010 — Serialized transactional workspace repository
- ADR 0011 — Transactional appearance drafts and owned transient presentation
- ADR 0007 — Separate product identity from connector authorization
