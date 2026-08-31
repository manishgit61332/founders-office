# 0017 — Bounded local entity operation outbox

- Status: Accepted
- Date: 2026-08-31
- Supersedes: ADR 0010 decision 6 and its whole-snapshot payload consequence

## Context

ADR 0010 made one transactional SQLite snapshot the Mac workspace authority and placed a second copy of that complete snapshot in every pending operation. That was a safe first migration step, but its cost grows with the whole workspace instead of with the changed entity. A single title edit in a 10,000-Move workspace therefore encoded and retained another multi-megabyte snapshot. Repeated offline edits amplified database size, write latency, and memory pressure.

The local outbox is not the public HTTPS sync contract. Remote entities, merge semantics, Supabase tables, and wire status names are still separately versioned work. In particular, the local historical status `.waiting` is displayed and transported as Blocked, and the legacy personalization document must be split across profile, workspace, Appearance, primary-goal, milestone, and asset authorities before network delivery.

Existing schema-1 databases can contain pending whole-snapshot operations. Some identify exactly one safe entity; broad personalization rows do not. An upgrade must preserve their operation identity, revision, writer, retry receipt, and content without silently translating an ambiguous snapshot into a wire mutation.

## Decision

1. Keep one canonical `FounderOfficeSnapshot` blob in `workspace_state`. New outbox writes use payload format 2 and contain one typed local entity record, an upsert or tombstone action, an entity kind and identifier, and a sorted changed-field mask.
2. Bound every encoded v2 payload to 256 KiB. Move details are bounded to 128 KiB; other scalar strings are bounded to 16 KiB. Entity identifiers, field names, custom Appearance identifiers, finite dates, finite goal values, accent stops, tombstone shape, and entity identity are validated before commit and again when pending rows are read.
3. Treat `changedFields` as authoritative. Fields present in a typed record but absent from the mask are validation context and must not overwrite a remote field. Profile operations exclude workspace naming, accent/Appearance, goals, milestones, and assets. Asset operations contain only the UUID-derived sync filename and bounded timestamps; original image names, dimensions, byte counts, extensions, and bytes never enter v2.
4. Keep the immutable operation ID, idempotency key, base and committed revisions, device-writer ID, field clocks, and delivery-attempt count outside the envelope. Store a fingerprint-format version with each receipt. New receipts hash a bounded metadata envelope plus the canonical snapshot digest; schema-1 receipts retain and replay the exact historical fingerprint algorithm.
5. Migrate a schema-1 row in place only when its metadata and decoded historical snapshot deterministically identify one v2 entity and pass every v2 bound. Preserve its operation identity, revisions, writer, retry receipt, and attempts. If any mapping is broad, unsupported, oversized, or cannot meet the stricter v2 shape, retain the exact v1 row as `requiresBootstrap`.
6. A `requiresBootstrap` row is never a normal transport operation. Ordinary delivery-attempt and acknowledgement APIs ignore it. Only after a sync coordinator has durably bootstrapped the exact current canonical workspace revision may it call the explicit legacy-bootstrap acknowledgement boundary; that boundary removes only v1 rows at or before that revision.
7. Introduce `WorkspaceLocalOperationTransportAdapter` as a compile-time seam, not an implementation of the wire contract. An adapter must explicitly map local `.waiting` to remote Blocked and split personalization entities. This ADR does not choose HTTP paths, backend columns, conflict algorithms, or connector behavior.
8. Canonicalize and encode the replacement snapshot once per transaction. Persist those exact bytes to `workspace_state`, and compute the v2 retry fingerprint from their SHA-256 digest so outbox bounding does not add another full-snapshot encoding pass.

## Consequences

- New pending-operation growth is proportional to the changed entity and capped independently of workspace size.
- The canonical state remains atomic and simple while future transport work receives typed, validated local operations.
- A historical broad v1 row can temporarily retain one whole snapshot until a durable bootstrap succeeds. This is a bounded compatibility path, not a format available to new writers.
- Typed records intentionally include enough entity context to validate tombstones and deterministic adapters. Transport implementations must honor the changed-field mask.
- Receipt rows continue to grow as described in ADR 0010; receipt-retention policy remains separate work.

## Privacy and security

- No diagnostics or benchmark output contains Move titles, details, names, image metadata, or payload bytes.
- Pending rows fail closed on unknown formats, malformed metadata, oversized payloads, invalid entity identity, non-finite dates or numbers, and unsafe strings.
- Multiline Move details remain valid: line feed, carriage return, and tab are permitted. Unsafe C0/C1 and bidirectional override/isolate controls are rejected, while legitimate format scalars such as emoji joiners remain valid.
- Exact image originals remain local-only. V2 stores asset metadata needed to identify the bounded sync variant, never the original.
- Legacy snapshots are decoded only under the 64 MiB compatibility ceiling and are never passed through the transport-adapter seam.

## Migration and rollback

Schema 2 adds `fingerprint_version` to operation receipts inside the same immediate transaction that inspects and optionally upgrades v1 rows. A migration error rolls back the column, row changes, and `user_version` together. Safely mapped rows are regenerated deterministically as v2; all others keep their original v1 payload bytes.

An older binary must not open a schema-2 database because repository downgrade refusal remains mandatory. Rollback therefore requires restoring a reviewed pre-migration database copy or exporting the current canonical revision through the supported recovery flow; it must never rewrite schema metadata manually.

## Verification

- Schema-1 Move fixtures, including multiline details, migrate in place and retain exact retry behavior.
- Broad schema-1 personalization remains `requiresBootstrap`, cannot have its attempts incremented or be individually acknowledged, and is removed only by an exact-current-revision bootstrap acknowledgement while adjacent v2 work remains pending.
- New writers cannot emit v1 or broad personalization operations.
- A 10,000-Move benchmark covers repeated warm mutations, payload and database growth bounds, and reopen behavior against the 250 ms local mutation p95 gate.

## Related work

- ADR 0003 — Moves, Blocked, Awaiting reply, and Needs You
- ADR 0006 — Composable, versioned Appearance personalization
- ADR 0010 — Serialized transactional workspace repository
- ADR 0013 — Adopt SQLite as the Mac workspace authority
- ADR 0016 — Bounded personalization image assets
