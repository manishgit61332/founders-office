# Changelog

All notable customer-visible changes are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versions for public releases.

## [Unreleased]

### Added

- A gated Founder’s Office download website whose Mac download remains unavailable until a signed and notarized release URL is configured.
- A versioned first-run Mac onboarding flow for the user’s name, local or iCloud storage, optional Calendar access, optional launch at login, the first Move, and notch interaction rehearsal.
- Fail-closed recovery for malformed workspace and personalization data, including a preserved recovery copy and blocked writes while recovery is required.
- A durable workspace identity that prevents missing or partially restored cloud data from being replaced with newly seeded defaults.
- A privacy-safe crash-loop detector, MetricKit runtime-health foundation, and a minimal safe mode with an incident identifier and explicit retry.
- A hardened Developer ID release and independent verification pipeline for signing, notarization, stapling, entitlements, architectures, checksums, and archive safety.
- Forty automated Swift tests with code coverage, release-archive attack fixtures, plus website build, lint, release-policy, security-header, and dependency-audit gates in CI.
- Architecture records for primary account identity, connector authorization, safe auto-remediation, and the Mac → iOS → Windows → Android platform sequence.
- A complete macOS application icon set and bundled Instrument Serif license notice.
- Privacy, support, security, and license surfaces on the private website, with restrictive browser security headers.
- Deadline-first Move sections shared by macOS and iOS, with Overdue, Today, Upcoming, and No deadline groups.
- A focused completion history that keeps today and yesterday visible while preserving older work behind Previous tasks.
- Mix-and-match appearance controls for full-spectrum 8-bit RGB accents, two-colour gradients, display and interface fonts, move-card styles, and glass, frosted, or solid-black surfaces.
- A versioned appearance model shared by macOS and iOS, with forward-compatible identifiers and legacy personalization fallback.
- Private-repository governance, pull-request and issue templates, repository safety checks, and automated CI.
- A versioned local pre-push gate for private repositories without hosted branch protection.
- Privacy-safe structured diagnostics using Apple Unified Logging.
- Durable decision and release records under `docs/`.

### Changed

- Codex runs are now scoped to the Founder’s Office workspace instead of the parent Application Support directory.
- Development builds and release builds now use separate scripts; the development path cannot accidentally produce a distributable release artifact.
- CloudKit now resolves one explicit, entitlement-matched container from the signed app instead of a source-code default.
- Existing beta workspaces remain local until their owner completes the new storage and privacy review.
- Customer Release builds compile external Codex CLI execution out until its separately scoped helper and consent gates pass.
- The codebase now passes complete Swift 6 concurrency checking with warnings treated as errors.
- Customer-facing “Open Loops” language is now **Moves**.
- The ambiguous “Waiting” state is now **Blocked** in the current interface.

### Fixed

- Corrupt canonical data can no longer be silently replaced with an empty default workspace.
- The Mac app no longer initializes workspace, cloud, calendar, image, animation, or Codex services while crash-loop safe mode is active.
- Snapshot and motion-capture launches now use synthetic calendar events instead of reading the signed-in Mac's calendars.
- Removed the clipped outer shadow that made the transparent lower notch corners look like a second rectangular container.
- Personalize now stays open while a calendar picker, colour panel, menu, or photo chooser is active, then resumes normal notch hover dismissal when the interaction ends.
- The finish-line calendar now applies a date only when **Done** is pressed; **Cancel** preserves the previous date.
- Release archives now reject extra payloads, links, special files, duplicate paths, unsafe expansion, incomplete metadata, and runtime CloudKit mismatches.
- Website HTML responses now receive the reviewed security-header policy at the Worker boundary instead of relying on static-asset configuration.
- The website download gate now derives from canonical sealed release metadata and rejects mutable aliases, query strings, mismatched origins, and noncanonical artifact names.

### Security

- Founder runtime data, photos, Codex runs, exports, support bundles, visual QA, credentials, and signing files are excluded from source control.
- Direct releases accept only a tracked production entitlement file and reject debug, temporary-exception, or unsafe code-signing entitlements.

## [0.10.0] - 2026-08-30

### Added

- Native macOS notch panel with Home, Moves, Calendar, and Personalize surfaces.
- Personal image widget, measurable primary goal, calendar aggregation, task completion, recoverable deletion, and launch-at-login preference.
- Shared Swift domain and CloudKit foundations for a native iPhone companion.

### Fixed

- Removed the outer shell seam and contextual footer band from the expanded notch.
- Made the dark frosted surface more transparent and retained only a top-weighted inner glow.
- Replaced hard-coded greeting behavior with saved preferred-name data.

[Unreleased]: https://github.com/manishgit61332/founders-office/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/manishgit61332/founders-office/releases/tag/v0.10.0
