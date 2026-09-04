# Founder’s Office client-interface draft v1

This directory documents portable, in-process client values that can be
implemented by native platform adapters. It is a **draft**, not the tagged or
frozen cross-platform contract. The final contract remains blocked on the Mac
distribution gate and production-equivalent Supabase RLS, RPC, idempotency,
offline convergence, export, and erasure acceptance.

The production HTTPS sync boundary remains in `contracts/v1`. Nothing in this
draft enables remote sync or authorizes platform beta worktrees.

## Transient presentation request

`TransientPresentationRequest` describes lifecycle policy without carrying a
window, view, responder, file path, title, or other platform/private data.
Native adapters own their UI object and balance the returned interaction lease.
Unknown fields, kinds, dispositions, and schema versions fail closed.

- Schema: `schemas/transient-presentation.schema.json`
- Example: `fixtures/transient-presentation.request.json`

## Appearance draft commit

`AppearanceDraftSession.save(policy:using:)` injects a Sendable
`AppearanceDraftCommitBoundary`. The boundary receives the exact draft,
baseline revision, and explicit conflict policy. It may report:

- `saved(committedRevision:)` only after that exact appearance is durable;
- `conflict(latest:)` with the latest durable appearance;
- `failed(_:)` with customer-safe, retryable copy.

The draft state machine handles `unchanged` without crossing persistence,
retains failed/conflicting previews plus the exact latest conflict value for
**Use Latest**, and advances its baseline only after a successful commit. The
boundary is intentionally not a JSON or HTTPS API: each native client adapts it
to its local transactional repository.
