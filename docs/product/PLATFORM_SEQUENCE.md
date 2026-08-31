# Platform sequence

Do not clone the Mac interface onto every device. Share the domain model, sync protocol, policy engine, and design tokens. Build each shell with the platform's native interaction model.

## 1. Production Mac app

Exit only after signed and notarized distribution, safe storage recovery, onboarding, permission retention, performance budgets, export/erase, and a controlled alpha pass.

## 2. iPhone app

Use the existing SwiftUI target. Verify identity, App Group storage, Cloud migration, background behavior, Dynamic Type, VoiceOver, and real-device sync before adding a widget.

## 3. iOS widget

Build a WidgetKit extension that reads a small App Group projection. It shows the next Move, next event, or primary goal. It does not read the full canonical store, run an agent, or perform destructive work. Tapping opens the exact item in the app.

## 4. Cross-platform account and sync authority

Use Supabase Auth with Google and Apple product identities plus the versioned
Supabase Postgres sync contract for workspace tenancy, encrypted transport,
revisioned changes, deletion, activity history, and connector mappings. Migrate
Apple workspaces once. Do not run CloudKit and Supabase as permanent competing
writers.

## 5. Windows app

Use a native Windows shell with WinUI 3 and MSIX. Use a tray/menu-bar equivalent and a compact top-edge focus surface. Do not imitate a MacBook notch on hardware that has none. Require signed packaging, startup consent, Windows accessibility, and the same recovery tests.

## 6. Android app and widget

Build the Android app before the widget. Use the app for sign-in, workspace recovery, editing, connection management, and configuration. Use Jetpack Glance for a passive, glanceable widget backed by a bounded local projection. Prefer event-driven refresh and WorkManager; never poll every few minutes.

## Shared acceptance contract

Every platform must pass:

- account isolation and two-accounts-from-one-provider tests;
- offline edits, conflict convergence, upgrade, downgrade refusal, export, and erase;
- denied, revoked, and restored permissions;
- accessible text, keyboard/switch navigation, contrast, and reduced motion;
- cold launch, memory, animation, background energy, and crash-loop budgets;
- signed release provenance and rollback.

References: [WidgetKit](https://developer.apple.com/documentation/widgetkit), [Windows App SDK](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/), and [Jetpack Glance](https://developer.android.com/develop/ui/compose/glance).
