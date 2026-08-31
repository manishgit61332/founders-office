# Changelog

All notable customer-visible changes are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versions for public releases.

## [Unreleased]

### Added

- A configuration-gated Supabase product-identity client for Google OAuth and native Sign in with Apple, with PKCE, Keychain session storage, token-free UI state, and an explicit local-workspace claim decision before sync can begin.
- A serialized, transactional local workspace repository foundation with durable revisions, device-writer identity, idempotent mutation receipts, a sync operation outbox, fail-closed legacy import, and immutable JSON/Markdown exports.
- Transactional Appearance editing with live preview, explicit Save Changes and Discard actions, conflict choices, retryable save errors, and an unsaved-quit guard.
- A centralized transient-presentation lifecycle that collapses the expanded notch for native panels, menus, and popovers, keeps overlapping interactions balanced, and restores the notch and keyboard focus after the final popup closes.
- A gated Founder’s Office download website whose Mac download remains unavailable until a signed and notarized release URL is configured.
- A versioned first-run Mac onboarding flow for the user’s name, local or iCloud storage, optional Calendar access, optional launch at login, the first Move, and notch interaction rehearsal.
- Fail-closed recovery for malformed workspace and personalization data, including a preserved recovery copy and blocked writes while recovery is required.
- A durable workspace identity that prevents missing or partially restored cloud data from being replaced with newly seeded defaults.
- A privacy-safe crash-loop detector, MetricKit runtime-health foundation, and a minimal safe mode with an incident identifier and explicit retry.
- A hardened Developer ID release and independent verification pipeline for signing, notarization, stapling, entitlements, architectures, checksums, and archive safety.
- Seventy-nine automated Swift tests with code coverage, release-archive attack fixtures, plus website build, lint, release-policy, security-header, and dependency-audit gates in CI.
- Architecture records for primary account identity, connector authorization, safe auto-remediation, and the Mac → iOS → Windows → Android platform sequence.
- A complete macOS application icon set and bundled Instrument Serif license notice.
- Privacy, support, security, and license surfaces on the private website, with restrictive browser security headers.
- Deadline-first Move sections shared by macOS and iOS, with Overdue, Today, Upcoming, and No deadline groups.
- Priority lanes shared by macOS and iOS, with labeled Critical, High, Medium, and Low side rails plus drag-to-reprioritize interactions.
- A Priority / Due view switch for Moves, aligned trailing dates, and selected-day Move deadlines inside Calendar.
- Compact macOS event creation with all-day support and an account-aware writable-calendar picker that distinguishes multiple Google accounts.
- A focused completion history that keeps today and yesterday visible while preserving older work behind Previous tasks.
- Mix-and-match appearance controls for full-spectrum 8-bit RGB accents, two-colour gradients, display and interface fonts, move-card styles, and glass, frosted, or solid-black surfaces.
- A versioned appearance model shared by macOS and iOS, with forward-compatible identifiers and legacy personalization fallback.
- Private-repository governance, pull-request and issue templates, repository safety checks, and automated CI.
- A versioned local pre-push gate for private repositories without hosted branch protection.
- Privacy-safe structured diagnostics using Apple Unified Logging.
- Durable decision and release records under `docs/`.

### Changed

- Provider-supplied account names are now non-authoritative onboarding suggestions; only an explicitly reviewed, NFC-normalized display-name value can cross a durable identity update boundary.
- App-owned Mac and iPhone typography now uses one three-role hierarchy: a 28-point primary title, a secondary size divided by 1.62, and a tertiary size divided again by 1.6.
- The Appearance accent editor now uses one compact macOS-style control surface with a native segmented mode picker, exact colour wells, and a focused gradient-direction slider instead of loose oversized controls and technical helper copy.
- Codex runs are now scoped to the Founder’s Office workspace instead of the parent Application Support directory.
- Development builds and release builds now use separate scripts; the development path cannot accidentally produce a distributable release artifact.
- CloudKit now resolves one explicit container from product configuration instead of a source-code default; macOS also verifies the signed process entitlement, while iOS relies on its provisioning profile and CKContainer enforcement.
- Existing beta workspaces remain local until their owner completes the new storage and privacy review.
- Customer Release builds compile external Codex CLI execution out until its separately scoped helper and consent gates pass.
- The codebase now passes complete Swift 6 concurrency checking with warnings treated as errors.
- Customer-facing “Open Loops” language is now **Moves**.
- The ambiguous “Waiting” state is now **Blocked** in the current interface.

### Fixed

- Appearance controls no longer write personalization data or advance modification timestamps before Save Changes succeeds.
- Native colour, date, menu, and file-picker surfaces now remain above the physical notch instead of falling outside its hover lifecycle.
- Buttons and selected priority controls now calculate black-or-white foreground contrast from the customer’s exact accent colour instead of assuming white text will remain readable.
- Dark custom accents used as functional text now fall back to a readable neutral while retaining the chosen colour in markers, borders, and fills.
- Corrupt canonical data can no longer be silently replaced with an empty default workspace.
- The Mac app no longer initializes workspace, cloud, calendar, image, animation, or Codex services while crash-loop safe mode is active.
- Snapshot and motion-capture launches now use synthetic calendar events instead of reading the signed-in Mac's calendars.
- Synthetic Calendar previews no longer fall through to EventKit when the event form refreshes its destination picker.
- A later offline priority or deadline edit can no longer erase a newer completion or resurrect a deleted Move during cloud merge.
- Calendar event defaults now remain on the selected day near midnight, and multi-day events are labeled as continuing instead of repeating their original start time.
- Failed iPhone priority changes now surface an explicit error instead of silently leaving the Move unchanged.
- Removed the clipped outer shadow that made the transparent lower notch corners look like a second rectangular container.
- Personalize now stays open while a calendar picker, colour panel, menu, or photo chooser is active, then resumes normal notch hover dismissal when the interaction ends.
- The finish-line calendar now applies a date only when **Done** is pressed; **Cancel** preserves the previous date.
- Release archives now reject extra payloads, links, special files, duplicate paths, unsafe expansion, incomplete metadata, and runtime CloudKit mismatches.
- Website HTML responses now receive the reviewed security-header policy at the Worker boundary instead of relying on static-asset configuration.
- The website download gate now derives from canonical sealed release metadata and rejects mutable aliases, query strings, mismatched origins, and noncanonical artifact names.

### Security

- Product-auth callbacks now use an explicit provisional-custom-scheme or HTTPS universal-link allowlist, rejecting executable, file, data, insecure HTTP, credential-bearing, and route-mismatched URLs.
- Production identity configuration accepts only HTTPS endpoints and Supabase publishable/legacy-anon keys; secret and service-role credentials are rejected before the client is created.
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
