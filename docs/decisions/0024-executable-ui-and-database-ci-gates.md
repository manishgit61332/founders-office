# 0024 — Executable UI and database CI gates

- Status: Accepted
- Date: 2026-09-01
- Extends: ADR 0011, ADR 0015, and ADR 0020

## Context

Compiling an XCUITest target does not prove that the app launched or that a
native panel completed its lifecycle. Parsing SQL and checking policy strings
does not prove that PostgreSQL applied the migrations, enforced RLS, or executed
the RPC tests. Both shortcuts can produce a green check while the release gate
they describe remains unexecuted.

The repository also needs to remain credential-free. CI must not acquire a
production Supabase project or Apple distribution identity merely to exercise
deterministic local behavior.

## Decision

1. The full-Xcode macOS job generates the project with the pinned XcodeGen
   binary and invokes `xcodebuild test` serially against the Mac scheme. It uses
   a temporary ad-hoc signature with provisional product entitlements removed;
   every scenario uses a synthetic temporary workspace. A failed run uploads
   its `.xcresult` bundle.
2. Native colour panels receive a stable accessibility identifier only while
   owned by the transient coordinator. Required colour-panel scenarios fail if
   the panel cannot be observed. They cannot call `XCTSkip`.
3. Static sync validation remains a fast credential-free parser gate. A
   separate Linux job pins the official Supabase setup action and CLI, starts
   the exact expected local Supabase Postgres image, reapplies migrations, and
   executes the pgTAP RLS/RPC suite.
4. CI-local database evidence and production evidence are different claims. A
   green local job cannot satisfy production deployment, live identity/session,
   Storage, revocation, backup, or cross-account verification gates.

## Consequences

- CI fails when the UI test process cannot expose a required native panel,
  instead of reporting a compile-only or skipped success.
- SQL policy regressions fail in a real database without using a service-role
  key, OAuth secret, or networked Supabase project.
- The database job is slower than the static parser, so the parser runs first
  and the database runs independently from Mac and website work.
- GitHub runner execution is still required. This ADR and workflow syntax alone
  are not a passing run.

## Privacy and security

UI tests use synthetic names, Moves, events, and temporary local roots. Database
tests create synthetic Auth identities inside rolled-back transactions. Failed
UI artifacts can contain only those fixtures. CI receives no production
credentials and contacts no production Supabase project.

## Migration and rollback

No customer data or schema version changes. Rollback removes the extra CI job
and returns the native colour panel's temporary accessibility metadata when the
panel closes. Such a rollback also reopens the release-evidence gaps and must be
recorded as a blocked gate.

## Verification

- Local source parsing and AppKit unit tests verify the accessibility marker is
  assigned and restored.
- GitHub Actions must produce a green `xcodebuild test` result on macOS and a
  green 97-assertion pgTAP result on the pinned Linux database job.
- The production RLS and identity evidence listed in the launch gate remains
  unpassed until it is gathered from the approved deployed environment.

## Related work

- [Transactional appearance and transients](0011-transactional-appearance-and-transients.md)
- [Supabase Auth and revisioned sync](0015-supabase-auth-and-revisioned-sync.md)
- [Mac UI automation](../product/MAC_UI_AUTOMATION.md)
- [Supabase local setup](../product/SUPABASE_LOCAL_SETUP.md)
