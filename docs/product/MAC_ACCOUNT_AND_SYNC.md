# Mac Account & Sync

## Release boundary

Account & Sync is a local-first identity surface inside Personalize. It does
not add a top-level notch tab. Every local feature works without an account.
When the signed bundle contains valid reviewed public configuration, the app
constructs the Supabase Auth client, bounded HTTPS transport, provisioning
service, and event-driven sync coordinator. Construction and sign-in alone do
not start sync. Missing or rejected public
configuration leaves the app in a concise **Stored on this Mac** state.

Google OAuth and native Sign in with Apple establish product identity only.
Calendar and future connectors require separate authorization. The Mac client
requests only `openid email profile`, and accepts only the reviewed
`founders-office://auth/callback` and `founders-office-dev://auth/callback`
custom schemes; an HTTPS callback must
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

Before any workspace binding, the user sees all dispositions:

- keep this workspace local-only;
- claim it as a new workspace;
- switch to an existing workspace; or
- export local work and replace it.

**Keep local-only** is always enabled. A configured customer runtime also enables
an explicit claim for a data-bearing unbound workspace and an explicit attach for
a repository-proven fresh device. Claim sends the local UUID without replacing
the snapshot; attach discovers with no local UUID and installs a complete
cursor-zero feed atomically. A matching durable binding resumes after secure
session restoration. A different account or provider cannot claim, attach, or
resume that binding.

**Export and replace** stays disabled until the native export destination and
immutable-export ceremony are connected to the account surface. Signing in never
uploads, replaces, or claims local data implicitly. Signing out stops the
coordinator but preserves the local binding, pending outbox, and canonical data
so the same account can resume safely.

Native authentication owns a transient-presentation token, suspends the notch,
and restores it after the final provider outcome. In-notch review choices hold
a non-suspending token so pointer exit cannot dismiss an unfinished decision.
Health consumes the durable runtime sync state. It reports local-only until a
runtime-validated transport is bound and surfaces retry, conflict, authentication,
adapter, and contract states without customer content or credentials.

## Release configuration and remaining acceptance

The direct-release script requires an exact credential-free Supabase HTTPS
origin, a publishable/anonymous public key, and the reviewed production callback
scheme. It refuses service-role material and verifies all three values in the
exported app. OAuth client secrets remain only in Supabase provider settings.

The customer runtime is wired, but public beta still requires the production
Supabase project to have the reviewed migrations and RLS/RPC tests, exact Google
and Apple provider settings, physical two-account/two-device convergence evidence,
revocation acceptance, monitoring, private-asset export/deletion, and the normal
Developer ID/notarization gates.
