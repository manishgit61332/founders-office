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

CI installs the official Supabase setup action at immutable commit
`ab058987d8d6c725971f6cf9d0b5c98467e30bd1` (v1.7.1), requests CLI `2.98.2`,
and refuses any other CLI or database image. For this repository's PostgreSQL
15 configuration, that CLI resolves the exact local image to
`ghcr.io/supabase/postgres:15.8.1.085`.

Install that CLI version and a supported Docker runtime, then run the same local
database sequence:

```bash
test "$(supabase --version)" = "2.98.2"
supabase db start
supabase db reset --local --no-seed
supabase test db --local supabase/tests
```

`db start` creates a credential-free local Supabase Postgres authority and
applies the versioned migrations. `db reset` proves the migrations replay on a
fresh schema. `test db` runs the pgTAP suite as
anonymous, owner, unrelated, and deleted-account identities. The suite covers
RLS visibility, direct-write denial, RPC ownership checks, idempotent duplicate
operations, mismatched operation-ID reuse, one-workspace ownership, pull-only
cursor acknowledgement, disjoint stale-base merging, same-field conflicts, the
five-minute future-clock gate, exact decimals, content-free activity, fail-closed
asset transfer, and idempotent/non-resurrectable workspace erasure.

The tests insert synthetic `auth.users` rows inside a rolled-back transaction.
They do not call Google, Apple, Supabase Cloud, or any live network service.
The separate **Execute local Supabase RLS and RPC tests** job runs that sequence
on every CI trigger. The fast static validator runs before Docker starts so
malformed contracts fail quickly. On a development host without the pinned CLI
and Docker, only the
static validator and Swift tests run. A passing static check does **not** claim
that PostgreSQL or RLS executed.

A green local-database job proves the checked-in migrations and pgTAP suite on
that pinned local image only. It does **not** prove production deployment,
production grants, live PostgREST error mapping, live JWT/session revocation,
private-object transfer, Storage deletion, backup/restore, or tenant isolation
in the selected Supabase project. Those remain separate production evidence
requirements.

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
  ownership contract, plus a privileged adapter that exports and deletes the
  exact server manifest before it records private transfer proof; and
- a one-time, verified local-workspace claim and cutover. A remote-only legacy
  CloudKit workspace requires a separate migration build or utility; the Mac
  customer app has no CloudKit capability. CloudKit and Supabase must never be
  concurrent writers for the same workspace.

Session revocation is an explicit **unpassed production release gate**. The
checked-in local configuration uses a 3,600-second access-token lifetime. Signing
out, deleting an account, or revoking a refresh token does not by itself prove an
already-issued JWT unusable before that bounded expiry. Production must document
and accept the maximum window or implement and integration-test an official
Supabase-supported immediate-revocation design. This repository intentionally
does not invent a session-epoch claim that Supabase Auth does not issue.

The first bootstrap requires the customer-reviewed onboarding display name;
later bootstraps may omit it to preserve the reviewed `profiles.display_name`.
Do not silently copy a Google or Apple provider name, and never use a display
name or email as an account or workspace key.

Asset rows are disabled at the RPC boundary until export and erasure capabilities
are both verified. Exports still return a manifest and
`requiresPrivateStorageAdapter` so incomplete integrations are visible. Erasure
returns HTTP 503 and leaves the canonical workspace untouched unless exact
deletion proof exists.

Full account deletion must use this order: produce the requested export; have the
privileged private-Storage adapter prove deletion of the exact current manifest;
call `erase_workspace`; revoke connector grants; then delete the Supabase Auth
identity through the approved Admin integration. A database trigger returns 409
if the Auth identity is deleted while its workspace still exists. Successful
Auth deletion removes the account link from the erasure receipt but deliberately
retains the opaque workspace-ID tombstone, so another account cannot claim a
stale erased UUID. Do not expose direct `profiles` deletion as an account API.

## Client live-sync engine status

The repository includes a schema-4 SQLite sync-state boundary, an exhaustive
v2-local-to-v1-wire adapter for supported entities, a bounded HTTPS RPC
transport, and an event-driven coordinator. A Mac customer build now composes
those boundaries only when its public product configuration passes the production
validator. Missing or rejected configuration keeps the same binary local-only.
Construction and sign-in do not start a workspace request.

The provisioning boundary separates a new local claim from a returning-account
attachment. The Account & Sync surface enables claim only for a data-bearing
unbound workspace and direct attachment only for a repository-proven fresh
device. Attachment calls `bootstrap_workspace` without a local UUID, validates
the account/provider/device, reads the complete bounded feed from cursor zero,
and atomically establishes the replacement snapshot, binding, cursor, remote
revisions, and dedupe evidence. Customer-authored local data still requires the
explicit export-and-replace path, which remains disabled until its native export
ceremony is integrated.

Runtime activation requires an explicit local workspace claim/attachment or a
matching restored product session and durable binding. Public distribution still
requires the approved production endpoint and publishable key, deployed and
integration-tested RPC contract, RLS evidence, revocation decision, migration
plan, monitoring, and incident response. Without valid client configuration the
app remains local-only; adapter or contract failures stop safely.

Primary goals use the canonical exact `GoalDecimal` model and map its
`decimalValue` directly to `SyncJSONValue.number`; no sync path converts through
`Double`. Bootstrap plans are pinned durably until their exact acknowledgement,
and the workspace record returned by `bootstrap_workspace` establishes the
singleton's positive server revision before any later rename. Reviewed names are
bootstrap-only; ordinary profile operations are not silently discarded. Asset
upload/download/replacement remains disabled until private-object export and
erasure proof, including replacement tombstones, passes its release gate. A
current image or valid legacy resolved photo filename blocks bootstrap rather
than silently omitting private data.

## Identity and connector separation

`AuthSession` contains opaque Founder account, workspace, and device IDs plus the
Google-or-Apple product identity provider. Optional connector accounts—including
additional Google accounts—use independent `ConnectorAccountID` values and grants.
Disconnecting a connector cannot sign the customer out or change workspace
ownership. Product auth credentials must never be reused as connector credentials.
