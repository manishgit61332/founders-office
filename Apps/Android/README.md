# Founder's Office for Android — Development

This directory contains the native Android development app. It is not a Beta
or a release artifact.

## What is implemented locally

- Kotlin + Jetpack Compose app with Home, Moves, Calendar, and Settings.
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
- Android SDK Platform 35 and build tools
- Gradle 8.9 (or a standard checked-in Gradle wrapper when introduced by the
  Android build environment)

From the repository root:

```bash
gradle :androidApp:testDebugUnitTest :androidApp:assembleDebug
```

The development APK, when built, is at
`Apps/Android/build/outputs/apk/debug/androidApp-debug.apk`. Android's standard
debug signing key stays in the developer's home directory. Do not distribute
that APK, add a signing key to source control, or represent it as a Beta.

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
those gates.
