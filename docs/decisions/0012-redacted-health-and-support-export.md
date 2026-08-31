# ADR 0012: Redacted Health surface and preview-first support export

- Status: Accepted
- Date: 2026-08-31

## Context

Founder’s Office already records bounded local diagnostic events, but a customer could not see whether local data, sync, Calendar, launch at login, or assistant execution needed attention. A conventional support bundle that copied logs or application files would risk exposing Move titles, event titles, names, account data, prompts, paths, and credentials.

## Decision

The Mac app exposes one compact Health page with five structural checks: Local data, Sync, Calendar, Startup, and Assistant. Each check uses a finite condition, a fixed content-free explanation, an optional last-success time, and at most one bounded remediation.

Health remediation is limited to reloading an existing local projection, retrying queued sync work, refreshing Calendar, opening the relevant macOS settings page, or rechecking assistant availability. Health does not edit canonical data, reset accounts, change permissions, alter credentials, install code, or mark a Move complete.

Support export is an explicit allow list of 16 fields: report version, random incident identifier, capture time, app/build/platform/OS/architecture, and condition plus last-success time for the applicable checks. The export API has no input for display details, log text, user content, or file paths. Before a Save panel appears, the app shows every key and value that will be written. The report is saved locally as JSON and is never uploaded automatically.

## Consequences

Customers get a clear first diagnostic surface and can share a useful reproduction envelope without sharing their workspace. The report cannot diagnose failures that require raw content or stack traces; those require a separately consented engineering workflow. A new report receives a new incident identifier and reflects only the state visible in its preview.

## Privacy and security

Move and calendar titles, names, account identifiers, message bodies, prompts, tokens, credentials, file paths, and Unified Log payloads are excluded by construction. Metadata is reduced to a safe character set and bounded length. Automated tests assert the exact field allow list and prove that arbitrary component detail text cannot enter the JSON.

## Migration and rollback

No workspace migration is required. Removing the Health page does not modify local data or connector state. Existing diagnostics remain governed by ADR 0002.

## Related work

- `Sources/FounderOfficeCore/HealthStatus.swift`
- `Sources/OpenLoops/FounderOfficeHealthModel.swift`
- `Tests/FounderOfficeCoreTests/HealthStatusTests.swift`
- `docs/product/MAC_UI_AUTOMATION.md`
