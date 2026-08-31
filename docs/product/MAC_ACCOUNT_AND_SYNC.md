# Mac Account & Sync

## Release boundary

Account & Sync is a local-first identity surface inside Personalize. It does
not add a top-level notch tab and does not make the workspace transport live.
Every local feature works without an account. Missing or rejected public
configuration leaves the app in a concise **Stored on this Mac** state.

Google OAuth and native Sign in with Apple establish product identity only.
Calendar and future connectors require separate authorization. The Mac client
accepts only the reviewed `founders-office://auth/callback` and
`founders-office-dev://auth/callback` custom schemes; an HTTPS callback must
not be enabled until a separately reviewed associated-domain flow exists.

## Session and name gates

The controller restores the Keychain-backed session once per app lifetime. A
new session is not exposed as signed in until its user ID and tokens can be
read back from durable storage. Read, write, mismatch, or removal failures
fail closed as a secure-storage error without logging credentials.

A provider name is a suggestion, never a durable greeting. The user must
review a normalized display name before the account update and local profile
change occur.

## Existing local work

Before any future workspace binding, the user sees all dispositions:

- keep this workspace local-only;
- claim it as a new workspace;
- switch to an existing workspace; or
- export local work and replace it.

Only **keep local-only** is enabled in this build. The other actions remain
staged until the authenticated transport, export path, and conflict contract
pass their release gates. Signing in never uploads, replaces, or claims local
data implicitly.

Native authentication owns a transient-presentation token, suspends the notch,
and restores it after the final provider outcome. In-notch review choices hold
a non-suspending token so pointer exit cannot dismiss an unfinished decision.
Health consumes an abstract account/sync status signal and reports sync as off
until a runtime-validated transport is bound.
