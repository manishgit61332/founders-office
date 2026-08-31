# ADR 0025: Bounded derived-state repair and workspace-blind safe mode

- Status: Accepted
- Date: 2026-09-01

## Context

The product documentation allowed automatic repair of disposable state, but
the Mac client did not enforce the stated attempt, timeout, idempotency,
health-check, or evidence boundaries. A failing derived projection could retry
without one durable customer-visible stop condition. The crash-loop safe-mode
copy also implied that a workspace export was available even though safe mode
correctly avoids opening the workspace at all.

Automatic recovery must not become a second writer for the founder’s Moves or
settings. A timeout must also be truthful: cancelling a Swift task does not
prove that a non-cooperative operation has stopped.

## Decision

Founder’s Office uses a separate bounded-repair coordinator and JSON ledger
only for enumerated, derived operations: generated projections, disposable
caches, Calendar observer reattachment, and optional retryable network work.
The current product wires only generated projection repair.

Each request has a deterministic key made from the finite repair kind and a
structural generation number. The coordinator performs a read-only health
check before and after an attempt, applies a hard timeout, and durably records
only finite health/outcome enums, an attempt count, and timestamps. It permits
at most three attempts for the same key across relaunches. Concurrent requests
share one attempt. If a timed-out task ignores cancellation, that key remains
blocked until the task actually exits, so another repair cannot overlap it.

Three unsuccessful attempts—or an unreadable/unwritable safety ledger—produce
a customer-visible **Needs You** state in Health. A healthy manual/routine
projection refresh clears an existing failed-attempt budget.

Generated projection repair verifies the manifest, exact bounded file set,
byte counts, and SHA-256 digests. It refuses symbolic links and uses a stable
sibling backup so an interrupted replacement can be restored. It never writes
the SQLite workspace, legacy inputs, Recovery data, credentials, permissions,
installed code, or task state.

Crash-loop safe mode continues to initialize no workspace, sync, Calendar,
personalization, image, or assistant service. It cannot export the workspace.
It may save only a ten-field crash-state diagnostic containing the incident,
capture/build/platform metadata, safe-mode flag, and bounded pre-ready failure
count. That diagnostic is constructed without a workspace API.

## Consequences

- A derived-output failure stops deterministically instead of retrying forever.
- Health distinguishes a retryable projection issue from a **Needs You** stop.
- The ledger adds small asynchronous writes outside the canonical database and
  retains at most 64 content-free records.
- A non-cooperative timed-out task can keep one key blocked until process exit;
  this is safer than starting overlapping work.
- Safe mode provides useful support evidence but intentionally cannot recover
  or export customer content.

## Privacy and security

The repair API and ledger contain no arbitrary error, path, filename, account,
workspace, task, event, prompt, or credential fields. Raw errors are discarded.
The ledger is mode `0600`, bounded to 256 KiB, rejects symbolic links, and
fails closed when malformed. The crash-state report is an exact allow list and
is never uploaded automatically.

## Migration and rollback

No canonical schema migration is required. The ledger lives under the private
`RuntimeHealth` directory and is derived evidence. Rolling back the feature may
remove that ledger and the generated-projection coordinator without touching
SQLite, legacy inputs, Recovery data, or exports. A projection backup is either
restored on the next repair or removed only after the replacement verifies.

## Related work

- `Sources/FounderOfficeCore/BoundedRepair.swift`
- `Sources/FounderOfficeCore/SQLiteWorkspaceRepository.swift`
- `Sources/OpenLoops/WorkspaceSession.swift`
- `Sources/FounderOfficeCore/HealthStatus.swift`
- `docs/product/RELIABILITY_AND_AUTO_REMEDIATION.md`
