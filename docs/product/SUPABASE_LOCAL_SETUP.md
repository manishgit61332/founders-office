# Supabase contract setup

The approved cross-platform authority is Supabase Auth plus Supabase Postgres.
Google and Apple are the v1 product identity providers. This repository contains
the credential-free contract, migrations, policies, RPCs, and client domain
interfaces; it does not contain a production project reference or OAuth secret.

## Static validation

The static contract gate needs only Python 3 and Swift:

```bash
python3 Scripts/validate-sync-contracts.py
swift test
Scripts/check-repository-safety.sh
```

The validator parses both JSON Schemas and OpenAPI, resolves their references,
checks representative positive and negative fixtures, confirms the canonical RPC
surface, inspects migration security invariants, and confirms the pgTAP plan and
required identity/merge cases agree. It does not execute PostgreSQL.

## Local database validation

Install the Supabase CLI and a supported Docker runtime, then run:

```bash
supabase start
supabase db reset
supabase test db
```

`db reset` applies the versioned migrations. `test db` runs the pgTAP suite as
anonymous, owner, unrelated, and deleted-account identities. The suite covers
RLS visibility, direct-write denial, RPC ownership checks, idempotent duplicate
operations, disjoint stale-base merging, same-field conflicts, the five-minute
future-clock gate, export confirmation, and account/workspace erasure.

The tests insert synthetic `auth.users` rows inside a rolled-back transaction.
They do not call Google, Apple, Supabase Cloud, or any live network service.

If a local adapter needs environment variables, copy `.env.example` to the
gitignored `.env.local`. Leave the publishable key empty until the local CLI emits
one. Never put a service-role key or OAuth secret in a client environment file.

## Production configuration blockers

The contracts compile without these values, but live sign-in and remote sync stay
disabled until all of the following are approved and configured outside Git:

- a production Supabase organization, project, region, URL, and publishable key;
- Google OAuth web/native client IDs, secret, consent screen, verified domain,
  redirect URIs, and platform URL schemes;
- Apple Services ID/App ID, Sign in with Apple key, team ID, return URLs, and
  platform entitlements;
- reviewed account-linking, recovery, reauthentication, session storage,
  account-deletion, abuse prevention, backups, monitoring, and incident response;
- an asset-storage bucket and policies that match the `assets.storage_path`
  ownership contract; and
- a one-time, verified CloudKit/local-workspace claim and cutover. CloudKit and
  Supabase must not remain concurrent writers for the same workspace.

The first bootstrap requires the customer-reviewed onboarding display name;
later bootstraps may omit it to preserve the reviewed `profiles.display_name`.
Do not silently copy a Google or Apple provider name, and never use a display
name or email as an account or workspace key.

## Identity and connector separation

`AuthSession` contains opaque Founder account, workspace, and device IDs plus the
Google-or-Apple product identity provider. Optional connector accounts—including
additional Google accounts—use independent `ConnectorAccountID` values and grants.
Disconnecting a connector cannot sign the customer out or change workspace
ownership. Product auth credentials must never be reused as connector credentials.
