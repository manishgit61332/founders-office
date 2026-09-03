# ADR 0027 — Mac customer builds use Supabase as the sole cloud authority

- Status: Accepted
- Date: 2026-09-03
- Supersedes: ADR 0015 and ADR 0026 only where release packaging retained active CloudKit capability

## Context

ADR 0013 removed the legacy polling CloudKit JSON writer from the Mac runtime,
and ADR 0015 selected Supabase as the cross-platform authority. The Mac target
and release scripts nevertheless still linked the CloudKit module and required
CloudKit, APNs, container configuration, and release evidence. Those unused
privileges obscured the actual authority and could allow a future regression to
restore a competing writer.

## Decision

1. The normal Mac customer target does not link `FounderOfficeCloud`, include
   CloudKit runtime keys, or request CloudKit/APNs entitlements.
2. Sealed Mac release metadata names `supabase` as the sole sync authority.
   Packaging and independent verification reject retired CloudKit configuration
   and effective entitlements.
3. Existing legacy local JSON remains a read-only SQLite migration input. Any
   customer whose only current data is remote in CloudKit must use a separately
   reviewed, explicit migration build or utility before enabling Supabase.
4. A migration first verifies the complete source and resulting destination,
   then disables its CloudKit access before Supabase becomes authoritative. The
   two systems never run as concurrent writers.
5. An unreadable durable Supabase binding fails closed: local work remains usable,
   but claim, attach, and resume are disabled until the state is recovered.

## Consequences

- The Mac beta has one cloud writer and fewer production capabilities.
- A CloudKit container and push entitlement are no longer release prerequisites.
- Remote-only legacy CloudKit migration is not silently claimed as complete and
  remains an explicit production blocker for affected testers.
- iOS CloudKit code remains available for migration compatibility, but this ADR
  does not authorize it as a permanent writer beside Supabase.

## Privacy and security impact

The customer binary follows least privilege and cannot access the old CloudKit
container. Public Supabase configuration remains non-secret; privileged writes
remain behind authenticated RLS/RPC boundaries. No account, workspace, token, or
customer content is added to diagnostics or release evidence.

## Migration and rollback

Local JSON-to-SQLite migration is unchanged. A remote CloudKit migration requires
separate signed tooling and exact record/count verification. Rollback may disable
Supabase and stay local-only; it must not re-enable the retired CloudKit writer in
the customer app.

## Verification

CI inspects the Mac Info.plist, entitlements, target dependencies, and customer
sources. Release creation and downloaded-artifact verification also reject
CloudKit/APNs configuration and require Supabase as the sealed sync authority.

## Related work

- [0013 — Adopt SQLite as the Mac workspace authority](0013-adopt-sqlite-as-mac-workspace-authority.md)
- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0026 — Configuration-gated customer cloud-sync runtime](0026-configured-customer-cloud-sync-runtime.md)
- [Mac Account & Sync](../product/MAC_ACCOUNT_AND_SYNC.md)
