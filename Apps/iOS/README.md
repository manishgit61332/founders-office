# Founder's Office for iPhone

This is the native SwiftUI iOS source scaffold. It uses the shared
`FounderOfficeCore` models and rules, persists an offline working copy in the
provisional App Group container, and connects that mirror to the private
CloudKit database through `FounderOfficeCloud` and `CKSyncEngine`.

## Product structure

- Home, Loops, Calendar, and Settings are native `TabView` destinations.
- New Task lives inside Loops and in its toolbar. It is not a fifth tab.
- Loops use native `List` swipe actions for complete, reopen, and soft-delete.
- Settings uses `PhotosPicker` for the personal vision image.
- Calendar uses EventKit with every calendar account enabled in Apple Calendar.
  Two Google accounts are supported automatically when both are enabled on the
  device. The app asks only while authorization is undecided; later launches
  reuse the system permission and refresh automatically.

## Provisional signing identifiers

The following values are placeholders until they are created for the chosen
Apple Developer team and enabled on the App ID:

- App: `com.manish.foundersoffice.ios`
- iCloud container: `iCloud.com.manish.foundersoffice`
- App Group: `group.com.manish.foundersoffice`

`CloudAccountMonitor` verifies iCloud account availability. The shared sync
engine queues local edits, survives offline operation, merges task tombstones
and newer revisions deterministically, and mirrors remote changes back into the
local JSON files. The personal vision image is transported as a `CKAsset`.
Calendar authorization itself remains a device permission and is never stored
in CloudKit.

An iCloud account switch pauses workspace sync until the person explicitly
chooses whether to upload the device's local workspace or use the workspace in
the newly selected iCloud account.

## Generate and build

This source has not been compiled in this environment because full Xcode,
XcodeGen, a signed development team, and provisioning profiles are not present.

1. Install full Xcode and select it with `xcode-select`.
2. Install XcodeGen.
3. Open Xcode and sign in to the Apple Developer account.
4. Create/confirm the provisional identifiers above and enable iCloud CloudKit,
   Push Notifications, Background Modes / Remote notifications, and App Groups
   for the iOS App ID.
5. From `OpenLoops`, run `xcodegen generate --spec project.yml`.
6. Open `FoundersOffice.xcodeproj`, select the team, and run on a physical
   iPhone. Remote CloudKit notifications are not fully testable in Simulator.

The first stable signed install prompts for Calendar once. Rebuilding with the
same bundle ID and signing identity preserves that permission across updates.
