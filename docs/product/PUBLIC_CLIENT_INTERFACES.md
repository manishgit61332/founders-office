# Public client interfaces

FounderOfficeCore publishes platform-neutral state and policy. The Mac target
adapts those values to SQLite and AppKit; future native clients must supply
equivalent adapters instead of importing Mac frameworks or duplicating policy.

These interfaces are **drafts**. They are not frozen, tagged, or permission to
start Windows, iOS-widget, or Android worktrees. Freeze follows the signed Mac
release gate and production-equivalent sync acceptance described in
`PLATFORM_SEQUENCE.md`.

## Appearance

`AppearanceDraftSession` owns the committed baseline, preview draft, baseline
revision, dirty state, conflict state, and retryable error. Controls call only
`update(_:)`. `discard()` restores the baseline in memory.

`save(policy:using:)` accepts a Sendable `AppearanceDraftCommitBoundary`:

```text
draft + baseline revision + conflict policy
                   │
                   ▼
       native transactional adapter
          │        │         │
       saved    conflict    failed
```

The boundary reports `saved` only after the exact requested appearance is
durable. The core session handles unchanged drafts without a write, retains the
preview on conflict or failure, retains the exact latest durable value for the
subsequent **Use Latest** decision, and advances the baseline only from the
returned committed revision. SQLite details, remote sync, and customer data
never enter the public state machine.

The Mac `PersonalizationStore` is the current adapter. It still performs one
repository transaction with the existing Appearance revision precondition, or
an explicit overwrite only after **Keep Mine**.

## Transient presentation

`TransientPresentationRequest` is strict Codable data containing only:

- schema version;
- portable presentation kind;
- retain-or-suspend host disposition.

The AppKit `TransientPresentationCoordinator` accepts `present(request:)` for a
balanced unscoped lease and request-plus-owner/window overloads for native
ownership. FounderOfficeCore never exposes `NSWindow`. Object identity, focus,
window level, accessibility identifiers, and restoration remain inside the Mac
adapter. Overlapping requests retain reference-counted restoration semantics.

The draft language-neutral schema and fixture live under
`contracts/client-interfaces/draft-v1`. The production sync contract remains
separately versioned under `contracts/v1`.
