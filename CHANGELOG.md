# Changelog

All notable customer-visible changes are recorded here. This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic versions for public releases.

## [Unreleased]

### Added

- Deadline-first Move sections shared by macOS and iOS, with Overdue, Today, Upcoming, and No deadline groups.
- A focused completion history that keeps today and yesterday visible while preserving older work behind Previous tasks.
- Mix-and-match appearance controls for full-spectrum 8-bit RGB accents, two-colour gradients, display and interface fonts, move-card styles, and glass, frosted, or solid-black surfaces.
- A versioned appearance model shared by macOS and iOS, with forward-compatible identifiers and legacy personalization fallback.
- Private-repository governance, pull-request and issue templates, repository safety checks, and automated CI.
- A versioned local pre-push gate for private repositories without hosted branch protection.
- Privacy-safe structured diagnostics using Apple Unified Logging.
- Durable decision and release records under `docs/`.

### Changed

- Customer-facing “Open Loops” language is now **Moves**.
- The ambiguous “Waiting” state is now **Blocked** in the current interface.

### Fixed

- Removed the clipped outer shadow that made the transparent lower notch corners look like a second rectangular container.
- Personalize now stays open while a calendar picker, colour panel, menu, or photo chooser is active, then resumes normal notch hover dismissal when the interaction ends.
- The finish-line calendar now applies a date only when **Done** is pressed; **Cancel** preserves the previous date.

### Security

- Founder runtime data, photos, Codex runs, exports, support bundles, visual QA, credentials, and signing files are excluded from source control.

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
