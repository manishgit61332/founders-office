# Founder's Office for Android

This directory contains the native Android application and its fail-closed
release path. Local verification does not by itself create a distributable
Beta.

## What is implemented locally

- Kotlin + Jetpack Compose app with Home, Moves, Calendar, and Settings.
- A private-by-default first run, dark mode, edge-to-edge system UI, and the
  shared Founder’s Office launcher artwork.
- Local Move creation, editing, completion, reopening, soft deletion,
  Recently Deleted, and Undo.
- Room-backed local Moves, immutable per-entity outbox entries, conflict state,
  a device-local sync binding, and a small widget-only projection.
- A configuration-gated Google product-auth / Supabase RPC seam. Its default
  build has no endpoint, publishable key, client ID, callback, or live request.
- An explicit claim-or-attach policy. Product sign-in alone cannot upload,
  replace, or attach a local workspace.
- Event-driven, one-shot WorkManager sync scheduling; no periodic polling.
- Small and medium Glance widget layouts with a privacy-redacted mode and exact
  Move or Calendar deep links. The widget has no edit, account, agent, message,
  or destructive action.

The module reads test fixtures from `Contracts/v1/fixtures` directly. It does
not duplicate, modify, or freeze the shared v1 schemas.

## Build prerequisites

- JDK 17
- Android SDK Platform 36 and build tools
- The checked-in Gradle wrapper

From the repository root:

```bash
Scripts/verify-android-development.sh
```

The development APK, when built, is at
`Apps/Android/build/outputs/apk/debug/androidApp-debug.apk`. Android's standard
debug signing key stays in the developer's home directory. Do not distribute
that APK, add a signing key to source control, or represent it as a Beta.

## Signed release bundle

`Scripts/build-android-release.sh` builds a minified, resource-shrunk Android
App Bundle only when all reviewed public configuration and upload-signing
environment values are present. Passwords are never passed as command-line
arguments. The release task fails closed when configuration is absent,
partial, non-HTTPS, or points to a missing keystore.

Required environment names:

- `FO_PUBLIC_SUPABASE_URL`
- `FO_PUBLIC_SUPABASE_KEY`
- `FO_PUBLIC_GOOGLE_CLIENT_ID`
- `FO_ANDROID_UPLOAD_KEYSTORE_PATH`
- `FO_ANDROID_UPLOAD_KEY_ALIAS`
- `FO_ANDROID_UPLOAD_STORE_PASSWORD`
- `FO_ANDROID_UPLOAD_KEY_PASSWORD`

The upload keystore and every credential remain outside the repository.

## Live configuration and beta gates

The Android app accepts only reviewed public configuration from main
integration: a Supabase URL, publishable key, Android OAuth client/audience,
and exact registered callback. It must never receive a service-role key,
provider client secret, calendar grant, or connector secret.

Before any Android Beta, complete the independently recorded gates for native
Google product sign-in, PKCE callback validation, server-side session exchange,
secure session persistence, logout and account-switch isolation, RLS/RPC proof,
offline convergence, conflict review, revocation behavior, Calendar permission,
widget rendering on a physical device, accessibility, and signed release
provenance. A local fixture result or a development APK does not prove any of
those gates. See `docs/product/ANDROID_RELEASE.md` for the handoff checklist.
