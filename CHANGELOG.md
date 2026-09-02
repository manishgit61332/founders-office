# Changelog

All notable customer-visible changes are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versions for public releases.

## [Unreleased]

### Added

- A first native Windows 11 development shell using C# and WinUI 3, with a Windows-native top-edge surface, notification-area entry point, transactional offline SQLite repository, v1 sync-contract adapter, and a dedicated Windows build/test gate. This is a developer milestone, not a signed friend-beta installer.
- New Moves now accept an optional user-written description, and the full Move editor can read or change the title and description alongside priority and deadline in one save.
- A Vercel-compatible Next.js production build and project configuration for the Founder’s Office website while retaining the existing Sites/Cloudflare build path.
- A CI version-consistency gate that prevents the locally installed development app and the macOS Xcode target from presenting different version/build numbers.
- A content-free bounded-repair ledger and coordinator with stable idempotency keys, before/after health checks, hard timeouts, three-strike persistence across relaunches, and a Health **Needs You** stop.
- A workspace-blind safe-mode crash diagnostic containing only ten allow-listed incident/build fields; safe mode still does not open or export canonical data.
- Draft public client seams for transactional Appearance commits and strict,
  platform-neutral transient-presentation requests, without enabling remote
  sync or starting cross-platform client worktrees.
- An explicit, fail-closed provisioning seam that distinguishes claiming a local workspace from attaching an existing account workspace, including fresh-device and immutable export-and-replace authorization.
- A fail-closed clean-Mac acceptance record that binds restart, upgrade, export, erase, recovery, and staged-update checks to the exact sealed Mac artifact before the website can expose it.
- A fail-closed schema-4 live-sync core with durable binding, server revisions, pull cursor, exact bootstrap and acknowledgement receipts, conflict evidence, inbound deduplication, and quarantine for malformed historical clock masks.
- A schema-4 immutable bootstrap-attempt journal that safely replays partial server acceptance across local edits, crashes, and relaunches while retaining later outbox work.
- Explicit **Keep Mine** and **Use Latest** conflict review which retains exact local evidence until one atomic, user-chosen outcome is durable.
- A bounded Supabase HTTPS RPC transport and event-driven sync coordinator with strict nested response shapes, cancellation, push-before-pull ordering, coalesced manual/automatic runs, hard continuation budgets, and no polling.
- A versioned, typed local entity-operation envelope capped at 256 KiB, with strict identity, field, string, number, and date validation plus an explicit transport-adapter seam.
- A safe schema-1 outbox migration: deterministic single-entity operations upgrade in place, while broad historical snapshots require an exact-revision sync bootstrap before their protected acknowledgement boundary can remove them.
- Bounded personal-image assets with separate 1,600-pixel display and 960-pixel sync variants, plus an explicit **Export original…** action that preserves the exact customer-selected file.
- An Ed25519-signed Mac update channel with bounded exact-URL checks, deterministic staged rollout, pause and rollback evidence, a manual status-menu check, and an automatic check limited to once per day after onboarding.
- An offline update-feed signer that reads its private key only from a non-synchronizing macOS Keychain item or bounded standard input and refuses to replace existing output.
- A compact Mac Health page for local data, sync, Calendar, startup, and assistant execution, with content-free last-success signals and only bounded, reversible retry or settings actions.
- A preview-first redacted support report that shows every allow-listed field before saving and excludes Moves, events, names, paths, prompts, credentials, and log payloads by construction.
- An XcodeGen macOS UI-test target with deterministic scenarios for transactional Appearance, Move planning, Calendar creation, popup restoration, and support-report preview.
- A configuration-gated Supabase product-identity client for Google OAuth and native Sign in with Apple, with PKCE, Keychain session storage, token-free UI state, and an explicit local-workspace claim decision before sync can begin.
- A local-first **Account & Sync** page inside Personalize, with reviewed display-name confirmation, explicit existing-workspace choices, native Google and Apple sign-in, and honest Health status while the transport remains unavailable.
- A serialized, transactional local workspace repository foundation with durable revisions, device-writer identity, idempotent mutation receipts, a sync operation outbox, fail-closed legacy import, and immutable JSON/Markdown exports.
- Transactional Appearance editing with live preview, explicit Save Changes and Discard actions, conflict choices, retryable save errors, and an unsaved-quit guard.
- A centralized transient-presentation lifecycle that collapses the expanded notch for native panels, menus, and popovers, keeps overlapping interactions balanced, and restores the notch and keyboard focus after the final popup closes.
- A credential-free Supabase Auth and Postgres contract foundation for Google and Apple product identities, single-owner cross-platform sync, deterministic offline field merging, export, and erasure.
- Durable immutable-operation receipts, pull-only device cursors, exact-decimal goal values at the wire-contract boundary, and fail-closed private-asset export/erasure manifests for the sync contract.
- First-class synced milestone/countdown records so personalization dates survive bootstrap, pull, and export.
- A gated Founder’s Office download website whose Mac download remains unavailable until a signed and notarized release URL is configured.
- A versioned, local-first Mac onboarding flow for the user’s reviewed name, optional Calendar access, optional launch at login, the first Move, and notch interaction rehearsal.
- Fail-closed recovery for malformed workspace and personalization data, including a preserved recovery copy and blocked writes while recovery is required.
- A durable workspace identity that prevents missing or partially restored cloud data from being replaced with newly seeded defaults.
- A privacy-safe crash-loop detector, MetricKit runtime-health foundation, and a minimal safe mode with an incident identifier and explicit retry.
- A hardened Developer ID release and independent verification pipeline for signing, notarization, stapling, entitlements, architectures, checksums, and archive safety.
- More than one hundred automated Swift tests with code coverage, release-archive and signed-update attack fixtures, plus website build, lint, release-policy, security-header, and dependency-audit gates in CI.
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

- The canonical Mac development build is now 0.11.2 (build 16), matching the macOS project target and replacing 0.11.1 (build 15).
- Primary-goal current and target values now use one exact, nonnegative `numeric(30,8)`-compatible type across Mac, iPhone, SQLite snapshots, JSON projections, and local outbox records while retaining the existing JSON-number shape.
- Primary-goal bootstrap, push, pull, nullable values, date-only deadlines, and tombstones now preserve exact base-10 values without a `Double` conversion.
- New Move, profile, workspace, Appearance, primary-goal, milestone, and asset mutations now retain one bounded entity operation instead of another complete workspace snapshot; exact image-original metadata remains excluded.
- Workspace retry receipts now version their fingerprint algorithm so schema-1 idempotent retries remain valid while new mutations avoid a redundant full-snapshot fingerprint encoding pass.
- The Mac personal-image widget now renders only a bounded ImageIO thumbnail; file copies, thumbnail generation, export, and cleanup run outside the main actor.
- The Mac app now uses one transactional SQLite workspace for Moves, personalization, goals, Appearance, tombstones, revisions, idempotency receipts, and sync outbox operations. Legacy JSON and Recovery files remain byte-for-byte migration inputs; JSON and Markdown are generated as immutable revision projections.
- The legacy polling-based Mac CloudKit JSON bridge has been removed so it cannot compete with the canonical workspace. Cross-device sync remains unavailable until the new authenticated sync contract passes its release gate.
- Provider-supplied account names are now non-authoritative onboarding suggestions; only an explicitly reviewed, NFC-normalized display-name value can cross a durable identity update boundary.
- Product identity now publishes a signed-in state only after its secure session can be read back durably, and Mac OAuth accepts only the reviewed custom callback schemes supported by the current native browser session.
- First-run setup no longer offers the retired CloudKit writer. It starts locally and explains that Google or Apple sign-in is a later, explicit Account & Sync choice; existing local data is never uploaded from onboarding.

- App-owned Mac and iPhone typography now uses one three-role hierarchy: a 28-point primary title, a secondary size divided by 1.62, and a tertiary size divided again by 1.6.
- The Appearance accent editor now uses one compact macOS-style control surface with a native segmented mode picker, exact colour wells, and a focused gradient-direction slider instead of loose oversized controls and technical helper copy.
- Codex runs are now scoped to the Founder’s Office workspace instead of the parent Application Support directory.
- Development builds and release builds now use separate scripts; the development path cannot accidentally produce a distributable release artifact.
- CloudKit now resolves one explicit container from product configuration instead of a source-code default; macOS also verifies the signed process entitlement, while iOS relies on its provisioning profile and CKContainer enforcement.
- Existing beta workspaces remain local until their owner completes the new storage and privacy review.
- Customer Release builds compile external Codex CLI execution out until its separately scoped helper and consent gates pass.
- Customer Release builds now omit the complete development assistant runner, its task actions, status UI, callbacks, and identifying strings rather than retaining an inert shell.
- Redacted support-report JSON encoding and atomic file writes now run on a dedicated storage actor so the notch remains responsive during export.
- The codebase now passes complete Swift 6 concurrency checking with warnings treated as errors.
- Customer-facing “Open Loops” language is now **Moves**.
- The ambiguous “Waiting” state is now **Blocked** in the current interface.

### Fixed

- The native Windows shell now uses the supported WinUI Mica backdrop API, preventing its code-behind failure from cascading into opaque XAML compiler errors.
- Priority drag release now completes from the persistent scroll surface when its lazy source row moves off-screen; the final pointer position selects the saved lane, and edge scrolling stops cleanly at the document boundary.
- Priority dragging now tracks the pointer in stable native viewport coordinates, so edge auto-scroll continues when the cursor is held still and lazy rows move beneath it.
- First-run onboarding now renders as one continuous squircle with fully transparent exterior corners instead of a clipped rectangular host shadow.
- A clean quit during asynchronous Mac startup no longer counts as a pre-ready crash. The development installer now requests an AppKit termination, waits for the process to exit, and refuses to replace a live bundle; real abrupt failures and an active safe-mode latch remain preserved.
- The safe-mode alert now offers the reset action directly, and local development bundles include the production app icon instead of macOS’s generic placeholder.
- Mac priority dragging now magnetically acquires the nearest lane and scrolls continuously at the top or bottom edge, with speed based on pointer proximity and balanced notch hold-open cleanup.
- Home now removes a timed Calendar event from **Up next** after its end time passes, while ongoing, overnight, and all-day events remain eligible until their exclusive end.
- A server-accepted Move whose push response is lost is now verified and acknowledged from the authenticated pull feed in one transaction, preventing the immutable operation from being retried with a different base revision after relaunch.
- Corrupt or missing generated projections now rebuild through a verified reversible backup without changing SQLite, while linked paths are refused and timed-out non-cooperative repairs cannot overlap another attempt.
- **Use Latest** now adopts the exact durable Appearance returned by a save
  conflict instead of depending on a second store read that could be stale.
- Existing-workspace attachment now rejects regressing feed horizons and skipped or duplicate entity revisions, and it removes stale schema-4 bootstrap journals inside the atomic authority-replacement transaction.
- A second device can now retain its local database identity while atomically binding a different existing remote workspace UUID; account, provider, device, feed, cursor, and remote revisions must all verify before canonical replacement.
- Account restore can no longer race a second sign-in, delayed transient auth events cannot replace a terminal result, and an identity change during name review cannot apply the prior account’s name to the local workspace.
- Keychain read failures can no longer be reported as a signed-out local-only state, and session durability now verifies the complete persisted account/session record rather than tokens alone.
- Primary-goal editors now reopen every meaningful decimal digit instead of rounding non-integers to one place, and malformed, non-finite, over-scale, negative, or out-of-range input fails before changing canonical state.
- Keyboard-opened colour panels now inherit the notch's interaction lease even when the pointer is elsewhere, and a failed Move or personalization write blocks quit until a later durable retry succeeds.
- Remote pull now applies field-scoped records, server clocks, dedupe IDs, and its cursor in one transaction without re-enqueuing an outbound operation; failed or interrupted pages roll back without cursor skip.
- Remote commits now advance the open Mac session exactly once while the sync coordinator ignores their origin, preventing both stale UI and outbox echoes.
- Sync retry delays now retain their failure streak and last successful run across cancellation and relaunch, and a scheduled status is written only when a live retry trigger exists.
- Clean sync runs no longer clear unresolved conflict review, **Keep Mine** now creates a fresh reviewed operation with winning clocks, and stale conflict review cannot overwrite a later local edit.
- Sync acknowledgements and bootstrap receipts now have bounded retention, while applied-operation dedupe, unresolved conflicts, and quarantined evidence fail closed instead of being erased unsafely.
- An older accepted pull value can no longer hide a newer pending same-field local edit; the local value remains visible while the remote revision and cursor advance safely.
- Canonical bootstrap can no longer delete pending work from a bare local revision: it requires exact authenticated server proof bound to the current workspace digest, account, device, results, and durable replay receipt.
- Bootstrap no longer sends a conflicting base-zero workspace rename after creating the singleton; the validated RPC workspace record seeds the positive server revision used by later renames.
- Automatic update throttling is now isolated by the reviewed feed URL, channel, and signing key, so a channel move or key rotation is checked immediately instead of inheriting another channel's delay.
- Repeated mutations in large workspaces no longer amplify the SQLite outbox by one full canonical snapshot per edit, and multiline Move details remain valid during strict v2 validation and schema-1 migration.
- Failed photo commits immediately roll back newly prepared files, successful replacement/removal retires prior owned variants only after the canonical SQLite commit, and launch reconciliation safely retries interrupted cleanup.
- Photo import now rebases onto the latest personalization state so a concurrent name, Appearance, goal, or milestone edit is not overwritten by slow image preparation.
- Rapid Mac mutations now serialize through component-scoped repository patches instead of racing whole-workspace JSON writes, and failed Appearance commits retain both the retryable draft and untouched committed value.

- Appearance controls no longer write personalization data or advance modification timestamps before Save Changes succeeds.
- Explicit close and quit now require a Save, Discard, or Cancel outcome for an unsaved Appearance draft; popup Escape and automatic hover dismissal preserve the draft and restore the notch only after the final popup closes.
- Native colour, date, menu, and file-picker surfaces now remain above the physical notch instead of falling outside its hover lifecycle.
- Status-menu submenus no longer suspend the notch, and display changes wait for an active native panel to finish before repositioning the expanded surface.
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
- Reusing a sync operation ID with different content now fails instead of silently treating the mutation as a duplicate.
- Workspace erasure now returns one durable idempotent receipt, blocks stale-ID resurrection, and refuses to orphan unverified private asset bytes.
- Bootstrap and push no longer advance a device cursor past changes the device has not pulled.
- Pull and conflict records now prove a server field clock for every field they claim changed or conflicted, and all wire DTOs are immutable after validation.

### Security

- Signing in cannot silently attach or replace a workspace: data-bearing replacement requires an immutable local export, failures leave the original canonical state untouched, and private image assets remain blocked.
- Remote sync remains disabled in the customer runtime. Unsupported ordinary profile operations and asset transfers fail closed; tokens and response content never enter workspace storage or diagnostics.
- Exact vision-image originals remain local and are never used by the notch or sync path; strict UUID-derived filenames, source/decompression/output bounds, private permissions, and path-safe cleanup prevent traversal and unbounded image handling.
- Direct Mac releases now require an independently reviewed update-feed URL, Ed25519 public key, and sandbox network-client entitlement; the app opens only a signed immutable download URL and never installs code itself.
- Support export is a local-only 16-field allow list; it never scrapes logs or workspace files and requires an exact on-screen preview before Save.
- The customer-binary verifier now rejects development assistant type, state, action, footer, status-copy, and callback sentinels in every shipped architecture.
- Product-auth callbacks now use only the reviewed provisional custom schemes supported by the native browser flow, and the completed response must match the configured scheme, host, port, and encoded path before Supabase receives its PKCE code. Universal links remain a separate unimplemented release gate.
- Production identity configuration accepts only HTTPS endpoints and Supabase publishable/legacy-anon keys; secret and service-role credentials are rejected before the client is created.
- Founder runtime data, photos, Codex runs, exports, support bundles, visual QA, credentials, and signing files are excluded from source control.
- Direct releases accept only a tracked production entitlement file, require the primary-app Sign in with Apple capability, and reject debug, temporary-exception, or unsafe code-signing entitlements.
- Activity metadata is an exact empty allow-list, product owners are limited to one workspace, and all canonical responses reject unknown contract versions.
- Immediate access-token revocation and the private Storage adapter remain explicit unpassed production gates; neither is represented as tested on this host.

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
