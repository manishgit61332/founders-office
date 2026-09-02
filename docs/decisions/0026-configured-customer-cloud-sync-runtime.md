# 0026 — Configuration-gated customer cloud-sync runtime

- Status: Accepted
- Date: 2026-09-02
- Supersedes: ADR 0022 only where it kept provisioning test-only

## Context

Founder’s Office already had reviewed product authentication, a bounded Supabase
transport, explicit workspace provisioning, durable sync state, and an
event-driven coordinator. The Mac customer process did not compose them. A
configured signed app therefore showed identity UI but could never bind or sync,
while the release script left unresolved build placeholders in its exported
Info.plist.

Enabling the components unconditionally would be unsafe. Product sign-in must not
become implicit consent to upload existing local work, and a missing or malformed
deployment configuration must not make local use unavailable. Product Google
identity also must not acquire Calendar, Gmail, or Drive authorization.

## Decision

1. A Mac customer process constructs the Supabase auth client, bounded transport,
   provisioner, and coordinator only when all public product configuration passes
   the existing production validator. Missing, unresolved, malformed, non-HTTPS,
   or unsafe-key configuration remains fully local-only.
2. Construction and product sign-in perform no workspace network operation. Sync
   begins only after an explicit claim/attach decision or after a secure session
   restore matches an existing durable account/provider binding.
3. A data-bearing unbound workspace may be explicitly claimed as new. A
   repository-proven fresh device may explicitly attach the account’s workspace.
   Export-and-replace remains unavailable until its native export ceremony is
   integrated. A different account or provider fails before transport use.
4. Signing out stops coordinator work but preserves canonical local data, the
   durable binding, cursor, and pending outbox. Only the matching identity may
   resume them.
5. Google product authentication requests exactly `openid email profile`.
   Calendar and every connector retain independent authorization, account IDs,
   consent, and credentials.
6. Each installation uses a stable random device UUID stored in local preferences.
   It is never derived from hardware, account, email, or customer content.
7. Direct signed releases require the public Supabase origin, publishable/anon
   key, and reviewed `founders-office` callback scheme. The release script refuses
   secret/service-role material and verifies the exact values in the exported
   application without printing them. OAuth client secrets remain server-side in
   Supabase provider settings.

## Consequences

- A correctly configured Mac build can now use the existing versioned backend
  without a second writer or polling loop.
- Development and misconfigured builds remain safely useful offline.
- Existing local work still cannot be uploaded merely by signing in.
- Returning customers can resume an approved binding; cross-account reuse is
  blocked.
- Production deployment and acceptance evidence remain external release gates,
  not conditions simulated by the client.

## Privacy and security impact

The runtime adds no email address, token, endpoint, key, or customer content to
diagnostics. The embedded Supabase key is a public client key protected by forced
RLS and RPC ownership checks; secret and service-role keys are rejected. Access
and refresh tokens remain in Keychain. Product identity grants no connector
scope. Sign-out never deletes or silently reassigns local work.

## Migration and rollback

No SQLite, Supabase, OpenAPI, or JSON Schema migration is required. Rollback can
omit runtime construction and return the app to local-only behavior without
changing canonical data. Existing bindings and outbox operations remain readable
by the reviewed sync core.

## Verification

Tests cover fail-closed missing/unresolved configuration, identity-only Google
scopes, explicit claim, fresh-device attach planning, cross-account binding
rejection, sign-out stop/preservation behavior, and stable opaque installation
identity. Release-policy tests reject secret keys and non-production callbacks.

## Related work

- [0015 — Supabase Auth and revisioned cross-platform sync](0015-supabase-auth-and-revisioned-sync.md)
- [0020 — Fail-closed local live-sync engine](0020-fail-closed-live-sync-engine.md)
- [0022 — Explicit existing-workspace provisioning](0022-explicit-existing-workspace-provisioning.md)
- [0023 — Durable sync runtime state and reviewed conflicts](0023-durable-sync-runtime-state-and-conflict-review.md)
- [Mac Account & Sync](../product/MAC_ACCOUNT_AND_SYNC.md)
