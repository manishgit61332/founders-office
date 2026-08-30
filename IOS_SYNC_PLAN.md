# Founder's Office: iPhone and Cloud Sync Plan

## Product Decision

Build a native SwiftUI iPhone companion around one shared Founder’s Office data model. Keep calendar access local to each device, and sync Founder’s Office data through the user’s private CloudKit database.

`openloops.json` remains the canonical Codex-facing mirror on the Mac. Cloud sync must not break the existing widget or `Scripts/openloops.py` workflow.

## Calendar: Connect Once Per Device

- Use EventKit on macOS and iOS. The system permission prompt should appear once per device, then the app reuses the saved authorization.
- A stable, consistently signed bundle is required. Replacing the current ad-hoc build changes the app identity and can make macOS ask again.
- Refresh automatically when EventKit reports a calendar change and whenever the app becomes active. “Connect Calendar” should become “Open Calendar Settings” only when access is denied.
- Read Apple Calendar, iCloud calendars, and every Google calendar already enabled in the device’s system Calendar accounts. Two Google accounts are supported; both simply appear as separate calendars.
- Do not store Google credentials, account identities, or raw calendar events in CloudKit. Calendar authorization is granted separately on the Mac and iPhone.

## Shared Architecture

```text
macOS notch app ─┐
                 ├─ FounderOfficeCore + shared repository
iPhone app ──────┘          │
                            ├─ atomic local store + sync outbox
                            └─ CKSyncEngine ─ private CloudKit custom zone
                                      │
macOS Codex bridge ─ openloops.json + personalization.json
        │
        └─ Scripts/openloops.py

EventKit on each device ─ system Calendar accounts (iCloud + Google)
```

The shared repository owns add, move, complete, delete, restore, sorting, migration, and conflict rules. Both UIs use the same domain types and mutation rules.

Use CloudKit records rather than a shared iCloud Drive JSON file. A private custom zone with `CKSyncEngine` supports offline edits, queued changes, incremental sync, and deterministic conflict handling.

## Cloud Data

Sync only Founder’s Office data:

- Open loops, including status and history.
- Primary goal, current value, target value, deadline, and milestones.
- Personalization, color choices, and the selected personal image as a `CKAsset`.
- Lightweight workspace settings that should follow the user between devices.

The first private beta uses one encrypted `WorkspaceSnapshot` record plus a
`CKAsset` for the personal image. The payload retains every open-loop UUID and
merges per item before any upload, so concurrent edits and tombstones converge.
If the workspace approaches CloudKit's practical record-size limit, migrate to
one record per task, workspace profile, primary goal, and milestone without
changing those UUIDs.

## Offline, Codex, and Conflict Rules

- Every local mutation is written atomically before it enters the CloudKit outbox.
- On macOS, accepted repository changes are exported atomically to `openloops.json` and `personalization.json`.
- Changes made by Codex or `Scripts/openloops.py` are imported as explicit mutations and then queued for CloudKit.
- A missing item in JSON never means delete. Deletion requires a `deletedAt` tombstone.
- For the same record, prefer the newest logical revision and `updatedAt`; use a stable writer ID as the deterministic tie-breaker.
- A newer restore clears the tombstone. Otherwise the newest deletion wins.
- Preserve completed and deleted records as history.
- Keep each iCloud account’s local cache isolated, and suspend sync safely during sign-out or account changes.

The iPhone widget should read a small App Group snapshot written by the main iPhone app. It should not run its own CloudKit sync engine.

## Native iPhone App

Use a system-first SwiftUI structure that feels consistent with the Mac app:

- Tabs: Home, Moves, Calendar, Settings.
- “New task” lives inside Moves, not in the tab bar.
- Home: next move, primary goal/countdown, up next, and the personal image widget.
- Moves: native lists, swipe complete/reopen/delete, Undo, filters, and fast capture.
- Calendar: a compact agenda from EventKit with all enabled system calendars.
- Settings: calendar status, iCloud sync status, personalization, image, colors, and launch/privacy controls.

Use native navigation, SF Symbols, Dynamic Type, accessibility labels, and platform controls. Retain Instrument Serif only for expressive headings; use San Francisco for interface text.

## Implementation Status

1. **Done in source:** `FounderOfficeCore` domain models, shared mutation rules,
   serialization, deterministic merge logic, and executable checks.
2. **Done in source:** atomic JSON repository, Codex context mirror, persisted
   CKSyncEngine state/outbox, tombstones, and account-switch isolation.
3. **Done in source:** macOS and iOS XcodeGen targets with provisional iCloud,
   push-notification, Calendar, and App Group entitlements.
4. **Done in source:** private custom-zone CKSyncEngine transport for tasks,
   goals, settings, milestones, and the personal image CKAsset.
5. **Done in source:** native iPhone Home, Moves, Calendar, and Settings screens.
   The read-only WidgetKit target remains a later addition.
6. **Blocked on Xcode/signing:** test first permission, relaunch, app updates,
   two Google accounts, offline edits, concurrent edits, delete/restore, iCloud
   sign-out, and recovery on physical Mac and iPhone devices.
7. **After device QA:** ship a private TestFlight build before considering a
   public App Store release.

## Current Blockers

This Mac currently has Command Line Tools only: no full Xcode installation, no Apple signing identity, no provisioning profiles, and no selected Apple Developer team. The installed macOS app is ad-hoc signed.

Therefore we can build and test the shared core, local repository, JSON bridge, and iOS source structure now, but we cannot create a durable CloudKit container, verify persistent calendar consent across signed updates, run the iPhone target, or distribute through TestFlight until:

- Full Xcode is installed.
- An Apple Developer account/team is selected in Xcode.
- Stable signing and provisioning are enabled for both apps.
- The final bundle, iCloud container, and App Group identifiers are registered.

## Provisional Identifiers

These are placeholders for Xcode setup, not registered production identifiers:

- macOS app: `com.manish.openloops` (retain the current bundle ID to minimize identity churn)
- iPhone app: `com.manish.foundersoffice.ios`
- iPhone widget: `com.manish.foundersoffice.ios.widget`
- iCloud container: `iCloud.com.manish.foundersoffice`
- App Group: `group.com.manish.foundersoffice`

Choose the permanent identifiers once, sign both apps with the same Apple Developer team, and do not change them after calendar permission and CloudKit production data are in use.
