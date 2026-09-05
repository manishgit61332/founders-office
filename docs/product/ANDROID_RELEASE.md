# Android release handoff

The Android app is a launch candidate only after both the repository-owned
gates and the account-owned gates below pass. Development success must not be
represented as a public Beta.

## Repository-owned verification

1. Run `Scripts/verify-android-development.sh`.
2. Run the connected Android tests on an Android 16 / API 36 emulator.
3. Verify onboarding, add/edit/complete/reopen/delete/restore/Undo, denied and
   granted Calendar access, dark mode, rotation, process relaunch, and widget
   deep links.
4. Run `Scripts/check-repository-safety.sh` and `Scripts/ci-checks.sh`.
5. Build the signed bundle with `Scripts/build-android-release.sh` only after
   the reviewed public configuration and upload-signing environment are ready.

## Account-owned gates

- Reserve and verify the permanent application ID and seller identity in the
  Play Console.
- Enrol the app in Play App Signing and custody a separate upload key outside
  source control and synchronized folders.
- Register the exact Android product-auth callback and both Play signing and
  upload certificate fingerprints with the identity provider.
- Supply only the reviewed Supabase origin, publishable key, and Android OAuth
  client ID. Never supply a service-role key or provider client secret.
- Complete production-equivalent RLS/RPC, two-account isolation, revocation,
  export, erasure, offline convergence, and recovery acceptance before enabling
  workspace claim, attach, or sync.
- Complete physical-device Calendar, widget, accessibility, cold-launch,
  memory, background-energy, and crash-loop checks.
- Complete the Play privacy policy, Data safety declaration, store listing,
  content rating, tester access, and staged-rollout review.

The application remains useful in local-only mode while remote workspace
provisioning is disabled. A signed artifact does not waive any product or data
integrity gate.
