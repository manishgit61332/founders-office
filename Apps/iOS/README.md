# Founder’s Office for iPhone

The iPhone app is a native SwiftUI shell for Home, Moves, Calendar, and
Settings. Its local authority is the shared `SQLiteWorkspaceRepository`; it
works offline and makes every Move edit through the durable entity outbox.
`FounderOfficeIdentity` supplies the product-only Google/Apple authentication
and the versioned Supabase bootstrap, push, pull, export, and erase transport.

## Account and data behavior

- A Google product sign-in uses PKCE in `ASWebAuthenticationSession` and stores
  the device session in Keychain. Product scopes are only `openid email profile`.
  They are never reused for calendar or future connector grants.
- Apple sign-in remains an entitlement-backed, disabled-until-configured parity
  seam. It joins the same Supabase product account model; it does not create a
  second workspace.
- Sign-in alone changes no workspace data. An existing data-bearing local
  workspace requires **Claim this local workspace**; an empty fresh device can
  explicitly choose **Use my existing workspace**. Account/provider mismatch
  stops before a request or replacement.
- Sign-out stops the coordinator and verifies removal of the local Keychain
  session. The durable opaque workspace binding remains so a different account
  cannot silently claim the prior local workspace.
- The outbox, retry state, remote cursor, conflict evidence, and conflict
  choices live in SQLite. The native Account & Sync surface exposes manual
  sync and a conservative **Keep my value** / **Use latest value** review.
- Device-calendar access remains a local EventKit permission. It is not a
  product login grant and cannot be copied to another operating system.

## Legacy and private assets

Supabase is the only active iOS cloud authority. The app does not construct a
CloudKit writer. Existing local legacy files remain read-only migration input;
remote-only legacy iCloud workspaces need a separate reviewed migration utility
that verifies source and destination before Supabase starts. The two writers
must never operate together.

Private vision images remain local. Existing image metadata is preserved and
blocks an otherwise unsafe claim/bootstrap until private-object export and
erasure verification is implemented. The app does not upload, erase, or quietly
omit those images.

## Widget prototype

`FoundersOfficeiOSWidget` reads only an atomic App Group file containing one
next Move, one upcoming local calendar commitment, and one primary goal. It
never opens the SQLite database, uses auth tokens, executes agents, sends
messages, or mutates data. The app clears the projection before secure-session
restore and again after sign-out; content is marked privacy-sensitive for the
system’s locked presentation. Widget availability on a physical device remains
dependent on a provisioned App Group entitlement.

## Build and beta gates

Run `xcodegen generate --spec project.yml`, then build the `FoundersOfficeiOS`
scheme with Xcode 16.4 or newer. Public config is supplied only through reviewed
build settings: the HTTPS Supabase URL, publishable key, and exact registered
callback. Do not add provider secrets or service-role keys.

This worktree does not contain Xcode, XcodeGen, an Apple Developer membership,
or a provisioned App Group. It therefore does not claim a simulator build,
physical-device sync, WidgetKit installation, TestFlight, or App Store beta.
Those remain explicit release gates after native compilation, Dynamic Type,
VoiceOver, account-isolation, offline-convergence, denied/revoked permissions,
and physical-device tests pass.
