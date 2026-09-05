# 0031 — Android local-first launch boundary

- Status: Accepted
- Date: 2026-09-05

## Context

The Android client must be useful before product authentication, calendar permission, or remote sync is configured. A public build also needs a permanent application identity, public OAuth configuration, upload signing, and current Play compatibility. None of those account-owned inputs should be guessed, embedded as secrets, or silently bypassed by a development build.

## Decision

1. Keep the development application ID separate from the customer application ID.
2. Start in a fully local workspace. Product sign-in and Calendar access are optional and separately consented.
3. Store product-session and PKCE material with an AES-256-GCM key held by Android Keystore. Exclude application data from platform backup.
4. Keep remote sync unavailable until its public configuration is valid and an authenticated workspace is explicitly provisioned.
5. Treat widgets as privacy-preserving projections of local data and route their intents through the app's supported deep links.
6. Target Android API 36 and require a signed, minified Android App Bundle for a release build.
7. Fail the release build when public service configuration, upload-signing inputs, or the upload keystore are absent or invalid.

## Consequences

The app can be installed and evaluated locally without an account. Signing in does not imply uploading an existing local workspace. Development builds cannot be confused with customer builds because their application IDs differ.

A distributable Play artifact cannot be produced until the product owner supplies the public service values and establishes custody of the upload key. Emulator tests establish repository-owned behavior, but they do not establish production OAuth approval, live sync convergence, Play Console acceptance, or physical-device behavior.

## Privacy and security

Move and Calendar content stays local unless the user explicitly enables a configured remote workflow. Tokens are encrypted at rest and are not eligible for backup. Build scripts accept signing passwords only through the process environment and do not print them or pass them on the command line.

## Migration and rollback

The Android package is pre-release, so no customer data migration is required. The session-store version is isolated from the legacy preferences name; logout clears both stores. Reverting this decision requires a replacement that preserves the distinct development identity, local-first usability, and fail-closed release gate.

## Related work

- ADR 0004 — Event-driven, approval-gated connectors
- ADR 0007 — Primary authentication and connector authorization
- ADR 0020 — Fail-closed live sync engine
- ADR 0022 — Explicit existing-workspace provisioning
- [Android App Bundle and Play App Signing](https://developer.android.com/studio/publish/app-signing)
- [Google Play target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878)
