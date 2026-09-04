# Platform sequence

Do not clone the Mac interface onto every device. Share the domain model, sync protocol, policy engine, and design tokens. Build each shell with the platform's native interaction model.

## 1. Production Mac app

Exit only after signed and notarized distribution, safe storage recovery, onboarding, permission retention, performance budgets, export/erase, and a controlled alpha pass.

## 2. Cross-platform account and sync authority

Use Supabase Auth with Google and Apple product identities plus the versioned
Supabase Postgres sync contract for workspace tenancy, encrypted transport,
revisioned changes, deletion, activity history, and connector mappings. Migrate
Apple workspaces once. Do not run CloudKit and Supabase as permanent competing
writers.

Do not tag the shared client contract until the Mac client and a
production-equivalent Supabase stack pass RLS, RPC, idempotency, offline
convergence, export, and erasure acceptance. Platform branches may not change a
tagged contract independently; proposed changes return to the integration
branch and require a new version.

## 3. Parallel platform betas

After the clean, tested Mac contract tag exists, create independent worktrees
from that exact tag:

```text
cross-platform integration
├── codex/windows-beta
├── codex/ios-widget-beta
└── codex/android-widget-beta
```

The worktrees run in parallel, but each platform reaches beta only after its
own native release gate passes. Development sub-agents are repository workers;
no agent runtime is embedded in a customer application or widget.

### Windows app

Use a native Windows shell with WinUI 3 and MSIX. Use a tray/menu-bar equivalent and a compact top-edge focus surface. Do not imitate a MacBook notch on hardware that has none. Require signed packaging, startup consent, Windows accessibility, and the same recovery tests.

### iPhone app and widget

Extend the existing SwiftUI app. Replace the legacy CloudKit writer with a
one-time, identity-safe migration into the shared repository; it must never run
beside Supabase as a competing authority. Verify product identity, secure
session storage, App Group storage, background behavior, Dynamic Type,
VoiceOver, and physical-device sync before enabling WidgetKit.

The WidgetKit extension reads only a small App Group projection. It shows the
next Move, next event, or primary goal, redacts sensitive content while locked,
and deep-links to the exact item. It never reads the full canonical store, runs
an agent, or performs destructive work.

### Android app and widget

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
