# ADR 0010: Transactional appearance drafts and owned transient presentation

- Status: Accepted
- Date: 2026-08-31

## Context

Appearance controls previously mutated and persisted the canonical personalization document on every colour, font, card, or surface change. Native AppKit panels, SwiftUI popovers, and menus also relied on independent hold-open leases and process-wide notifications, which made hover dismissal and focus restoration difficult to reason about.

## Decision

Appearance editing uses an in-memory `AppearanceDraftSession`. Controls change only the draft and retain its baseline revision. One explicit Save Changes action creates the new modification time and atomically writes a candidate personalization document before replacing the in-memory canonical value. Discard removes the draft. A newer durable appearance is adopted by a clean session or surfaced as a conflict beside a dirty draft. Save failures retain the preview and expose a retryable error.

Leaving Appearance, explicitly closing the notch, or quitting with a dirty draft requires Save, Discard, or Cancel. Automatic hover dismissal keeps the current session in memory and never persists it.

One AppKit `TransientPresentationCoordinator` owns native colour/file panels and scopes menu and popover notifications to the Founder’s Office panel. Its reference-counted lifecycle captures focus, collapses the expanded SwiftUI surface to the physical notch without destroying view state, orders the transient above the status-bar panel, and restores the expanded notch and focus only after the final presentation ends.

## Consequences

Appearance changes are intentional and recoverable instead of becoming durable while someone experiments. Popup behavior has one lifecycle and remains correct when presentations overlap. Native colour panels must be closed before the Save Changes row returns, matching the suspend-then-restore interaction.

The existing schema-version-6 appearance payload and legacy accent compatibility from ADR 0006 remain unchanged. Field-level cross-device merge is still future work.

## Privacy and security

Drafts live only in process memory and are discarded on an approved unsaved quit. No colour, font, focus, or popup content is logged. The coordinator tracks AppKit object identity only for the active presentation lifetime.

## Migration and rollback

No data migration is required. Rolling back restores immediate appearance persistence, so rollback must be treated as a customer-visible behavior regression. The pure draft and transient state machines can be removed without changing stored documents.

## Related work

- `Sources/FounderOfficeCore/AppearanceDraftSession.swift`
- `Sources/FounderOfficeCore/TransientPresentationSession.swift`
- `Sources/OpenLoops/PersonalizationStore.swift`
- `Sources/OpenLoops/TransientPresentationCoordinator.swift`
