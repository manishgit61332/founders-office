# Founder's Office

Founder's Office is a native Apple focus surface that turns the MacBook notch into a two-second view of the next meaningful move.

## What it does

- Opens when the pointer enters the notch area.
- Anchors the expanded panel to the physical top of the display so it grows directly from the notch, while keeping controls in the safe areas beside the hardware cutout.
- Expands from the notch with spring momentum and a small pointer-directed magnetic pull.
- Retracts into the notch after the pointer stays outside for 240 milliseconds.
- Reverses the existing spring when the pointer returns during retraction.
- Also opens from the menu bar checklist icon.
- Opens to an editorial Home view with one next move, one upcoming calendar signal, one primary goal, and a large personal-image widget.
- Pairs the bundled Instrument Serif display face with macOS San Francisco for functional UI, using bold white hierarchy instead of dense gray microcopy.
- Keeps Home, the full Moves board, and Calendar inside the same 720-by-350-point panel.
- Keeps the Home, Moves, Calendar, and Settings navigation in one fixed position on every screen.
- Uses one shared Apple-style visual system across every screen: Instrument Serif page titles, San Francisco UI text, neutral grouped cards, consistent borders, radii, and controls.
- Keeps the footer hidden unless it has a real transient action such as Undo or a Codex run result.
- Shows Doing, Next, Blocked, and Done.
- Groups active Moves by deadline urgency and keeps the default Done view focused on today and yesterday.
- Preserves older completed work behind Previous tasks instead of filling the daily view with history.
- Completes and reopens work with one click.
- Removes a task from every list without erasing it, with one-click Undo.
- Adds new moves from an action inside the Moves screen, separate from global navigation.
- Development builds can run research, writing, analysis, code, and local file work through Codex.
- Customer Release builds compile external Codex CLI execution out until the scoped-helper and consent launch gates pass.
- Commits Moves, personalization, goals, Appearance, tombstones, revisions, and pending sync operations through one serialized SQLite workspace.
- Generates bounded read-only JSON and Markdown projections after committed changes without rewriting the legacy migration files.
- Saves a workspace name, accent colour, chosen local photo, and one measurable primary goal in the same transaction authority. Photos use separate bounded display and sync variants; exact original bytes stay local until **Export original…** is explicitly chosen.
- Shows the primary goal as a target, current progress, and days left; it can also work as a deadline-only finish line when no numeric target is entered.
- Uses native SF Symbols and macOS-style hover, selected, and pressed states throughout navigation.
- Reads the next 30 days from every calendar enabled in macOS Internet Accounts—including iCloud and multiple Google accounts—after the user grants calendar access.
- Refetches events when EventKit reports a database change, when the app becomes active, whenever the notch opens, and on a 60-second safety interval.

`founders-office.sqlite3` is the canonical runtime state. JSON and Markdown under `Generated/revision-*` are bounded read-only projections for the user and local tools. The exact legacy JSON pair and Recovery data remain untouched migration inputs. All runtime data is intentionally excluded from Git.

Each workspace also has a local `workspace-identity.json`. First-run storage consent is bound to that durable identifier. If a previously known workspace is missing either canonical document, the app enters recovery before it can create defaults or start iCloud sync.

## Local development build

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh --install
open "$HOME/Applications/Founder's Office.app"
```

This command creates an ad-hoc signed development app in `dist/development/`. It embeds the current checkout path and is not notarized. Do not distribute it or connect it to the website download.

To exercise reviewed hosted sign-in in this same local app, create the ignored
`Configuration/ProductAuth.local.json` with only the public Supabase project
origin, publishable client key, and exact callback URL. `Scripts/build-app.sh`
validates and embeds those values before signing. It rejects service-role keys,
OAuth client secrets, unknown fields, and unsupported callbacks. Omit
`appleSignInEnabled`, or set it to `false`, until the signed app has the reviewed
Apple capability and provider configuration. See
[the Supabase setup guide](docs/product/SUPABASE_LOCAL_SETUP.md).

### Source preview for a technical friend

A technical tester can clone an explicitly approved commit and build the app on
their own Mac without an Apple Developer certificate. Replace `FULL_COMMIT_SHA`
with the 40-character commit supplied by the release coordinator:

```bash
git clone https://github.com/manishgit61332/founders-office.git
cd founders-office
git checkout FULL_COMMIT_SHA
Scripts/install-source-preview.sh --expected-commit FULL_COMMIT_SHA
```

This installs the same **Development** channel locally. It is not the external
Beta: the resulting app is ad-hoc signed, is not notarized, and remains tied to
that source checkout. Do not send its `.app` bundle or ZIP to another person,
do not bypass Gatekeeper, and do not use it to enable the website download.
The tester should inspect and trust the selected commit before running it.

The preview is local-only unless a separately reviewed development service is
configured. Keep the checkout because it contains the preview's private local
workspace. To update after reviewing the incoming commits:

```bash
git pull --ff-only
Scripts/install-source-preview.sh --expected-commit FULL_COMMIT_SHA
```

Export any work before deleting the checkout. A normal invited Beta still
requires the Developer ID-signed and notarized artifact described below.

Launch at login is opt-in. Right-click the checklist icon to enable or disable it.

## macOS release

Public downloads use a separate fail-closed path. The release script requires a clean tagged commit, final Apple identifiers, a production provisioning profile, Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper acceptance, and immutable checksum metadata.

See [the macOS direct-distribution runbook](docs/product/MAC_DIRECT_DISTRIBUTION.md). The website download must remain disabled until the sealed artifact passes the clean-Mac acceptance test.

Founder’s Office has only three named channels: **Development** for Manish’s local checkout, **Beta** for invited testers, and **Stable** for the public release. Testers receive only the latest signed Beta link; prior artifacts remain immutable for rollback evidence but are never presented as competing choices. See [the beta release workflow](docs/product/BETA_RELEASE_WORKFLOW.md).

## Command-line updates

```bash
python3 Scripts/openloops.py list
python3 Scripts/openloops.py add "Approve new homepage" --status next --priority P1 --due 2026-09-03
python3 Scripts/openloops.py move "Approve new homepage" doing
python3 Scripts/openloops.py done "Approve new homepage"
python3 Scripts/openloops.py delete "Approve new homepage"
python3 Scripts/openloops.py restore "Approve new homepage"
```

`list` reads the newest generated projection after SQLite migration. Mutating commands are supported only for an unmigrated legacy workspace; the script refuses to edit generated JSON once the database exists. Use the app for post-migration changes so the revision, receipt, and outbox remain atomic.

## Useful files

- `founders-office.sqlite3`: canonical transactional workspace state.
- `openloops.json` and `personalization.json`: preserved one-time migration inputs in legacy workspaces.
- `Generated/revision-*`: bounded read-only JSON and Markdown projections.
- `workspace-identity.json`: durable local workspace identity used to bind storage consent and fail closed during partial restores.
- `Scripts/openloops.py`: read interface for migrated projections and mutation interface only for unmigrated legacy workspaces.
- `Scripts/install-source-preview.sh`: fail-closed installer for a technical tester building an approved Development commit locally.
- `Scripts/validate-notch-geometry.swift`: verifies top-edge attachment and hardware-notch-safe header regions on the current display.
- `Resources/Info.plist`: contains the shared workspace path.
- `MOTION_SPEC.md`: documents the reveal, retraction, and reversal physics.
- `IOS_SYNC_PLAN.md`: the staged native iPhone and CloudKit migration plan.
- `GOOGLE_PHOTOS_INTEGRATION.md`: the scoped Google Photos Picker integration plan.
- `contracts/v1/`: the credential-free Supabase Auth and cross-platform sync contract, schemas, OpenAPI boundary, and fixtures.
- `CLAY_ICON_ASSETS.md`: historical clay-icon exploration retained for design history; the app now uses SF Symbols.
- `Resources/Fonts/InstrumentSerif-Regular.ttf`: bundled OFL display font used for the greeting and primary-goal emphasis.

## Repository workflow

- [CHANGELOG.md](CHANGELOG.md) records customer-visible changes.
- [docs/decisions](docs/decisions) records durable decisions.
- [docs/releases](docs/releases) records distributed-build evidence.
- [docs/LOGGING.md](docs/LOGGING.md) defines diagnostics, activity history, analytics, and AI-execution boundaries.
- [docs/GITHUB_WORKFLOW.md](docs/GITHUB_WORKFLOW.md) defines branches, checks, milestones, and the local push gate.
- [docs/product/ASSISTANT_ARCHITECTURE.md](docs/product/ASSISTANT_ARCHITECTURE.md) defines the safe assistant and connector model.
- [docs/product/LAUNCH_GATES.md](docs/product/LAUNCH_GATES.md) defines the evidence required before beta and launch.
- [docs/product/SUPABASE_LOCAL_SETUP.md](docs/product/SUPABASE_LOCAL_SETUP.md) explains local contract validation and the external configuration still required for live Google/Apple sign-in and remote sync.

Before a commit or pull request:

```bash
Scripts/check-repository-safety.sh
Scripts/ci-checks.sh
```

## Known boundary

The app must be running for notch hover to work. In development builds, Codex runs are local, review-gated jobs: they can create task artifacts in `Codex Runs`, but they cannot send messages, publish, book calls, purchase, use private credentials, or mark a task done. External CLI execution is compiled out of customer Release builds until a separately scoped helper, consent review, cancellation, retention, and cost controls are proven.

Local photo selection works now. Google Photos is deliberately not presented as connected until a Google Cloud project and OAuth client are configured; the current Photos Picker requires explicit user sign-in and selection.

Selected photos are copied without decoding the original, screened for file and decompression limits, and rendered through bounded ImageIO thumbnail APIs off the main actor. The notch never loads the retained original. A failed SQLite commit rolls back the new files, while replacement and removal delete prior owned variants only after the canonical commit succeeds.

Google Calendar does not need a separate OAuth flow inside Founder's Office. Add each Google account in System Settings → Internet Accounts, enable Calendar for each account, then grant Founder's Office Calendar access once. EventKit exposes those Google calendars and iCloud calendars through the same native store while keeping account names visible on events.
