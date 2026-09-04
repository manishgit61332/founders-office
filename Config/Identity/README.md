# Product identity configuration

Founder’s Office remains fully usable in local-only mode when this configuration is absent. Product sign-in is separate from Calendar, Google account, Gmail, Notion, Composio, or assistant connector authorization.

The Apple clients use Supabase Auth with:

- Google through OAuth and PKCE in `ASWebAuthenticationSession`, requesting
  only `openid email profile`;
- native Sign in with Apple through `AuthenticationServices` and a one-time nonce;
- session persistence in an app-specific Keychain service;
- a token-free account summary for UI and diagnostics.

## Required public build values

Supply these as Xcode build settings for a configured development build, or as
environment values to `Scripts/release-macos.sh` for a signed direct release:

```text
FOUNDER_OFFICE_SUPABASE_URL = https://PROJECT_REF.supabase.co
FOUNDER_OFFICE_SUPABASE_PUBLISHABLE_KEY = sb_publishable_...
FOUNDER_OFFICE_AUTH_CALLBACK_SCHEME = founders-office
```

The publishable key is intended for public clients, but it is still validated so a secret/service-role key cannot be embedded accidentally. Never place a Supabase secret key, service-role key, Apple private key, or OAuth client secret in the app or repository.

The reviewed production custom callback registered in Supabase is:

```text
founders-office://auth/callback
```

The client callback allowlist accepts that production scheme or
`founders-office-dev://auth/callback` for local development. It rejects all other schemes,
including `javascript`, `file`, `data`, and `http`, as well as callbacks with
credentials, query strings, fragments, or a different route. A production
universal-link flow would require an organization-owned domain,
associated-domain entitlements, an exact redirect registration, and a separate
client implementation; it is not accepted by this build. The direct-release
script accepts only `founders-office` and verifies the same scheme and callback
inside the exported signed application.

The browser result is checked a second time before Supabase sees its PKCE code.
The scheme, host, port, and encoded path must match the signed build's callback
exactly; only the OAuth query or fragment may differ.

## Reviewed display-name boundary

Google or Apple `user_metadata` names are exposed only as an in-memory
`OnboardingDisplayNameSuggestion`. They may prefill an onboarding control, but
they are not the durable profile name and must never flow directly into
workspace bootstrap. Native Sign in with Apple does not upload its returned name.

Only customer-entered or explicitly accepted input can become a
`ReviewedDisplayName` and cross a durable update boundary. Contract v1 applies
NFC normalization, trims surrounding Unicode whitespace, requires at least one
letter, number, or symbol, rejects control characters, line/paragraph separators, BOM, and bidi
controls, and permits at most 80 Unicode scalars and 320 UTF-8 bytes. The
Postgres profile constraint and RPC validation must mirror that versioned rule
before remote bootstrap is enabled.

Configure the Google provider and enable the final Apple App ID for Sign in with
Apple only after the selected callback form passes the release review.

## Workspace boundary

Signing in does not upload the current Mac workspace. After authentication the app must evaluate `WorkspaceClaimPlanner` and obtain one explicit decision:

- keep the current workspace local-only;
- claim it as a new cloud workspace;
- switch to the account’s existing workspace; or
- export the local workspace and then replace it.

Only the selected path may start the sync outbox. Switching accounts never
reuses another account’s workspace binding. A configured customer build now
constructs the reviewed transport and event-driven coordinator, but it performs
no network request merely because it was constructed or because a customer
signed in.

- A data-bearing, unbound Mac may explicitly claim its current workspace.
- A repository-proven fresh device may explicitly attach the account workspace.
- A matching durable binding may resume after secure session restoration.
- A binding for another account or provider fails before a request is sent.
- Signing out stops network work while preserving the local binding and outbox,
  allowing only the same account to resume them later.
- Export-and-replace remains unavailable in the customer UI until its native
  file-selection and immutable-export ceremony passes acceptance.

Missing, unresolved, or malformed public configuration always keeps the app in
local-only mode. The installation device ID is a random opaque UUID persisted
locally; it is not derived from hardware, an email address, or provider metadata.

## Secure injection

Keep the three public client values in the release system's protected environment
or local shell session and pass them directly to `Scripts/release-macos.sh`.
Do not source a credentials file into a tracked script, copy an `.env` file into
the application bundle, print the environment, or commit generated release
plists. The script validates the values, refuses `sb_secret_` and non-anonymous
JWT material, embeds only the public endpoint/key and exact callback, then
verifies the exported bundle without printing their values.

Google's OAuth client secret is entered only in the Supabase dashboard. It is
never a Mac build setting. Calendar, Gmail, Drive, Notion, Composio, and assistant
connections require their own separately explained consent and credentials; the
product identity session cannot grant those capabilities.

## External setup still required

Before a distributable beta, the product owner must provide the organization-owned domain, bundle IDs, callback scheme, Apple App ID/capability, Supabase project, Google OAuth credentials, and Apple provider configuration. RLS and RPC migrations must be deployed and their pgTAP suite must pass against that exact project. Production-equivalent two-account/two-device testing, revocation acceptance, monitoring, private-asset export/deletion, signing, and notarization remain release gates.

References:

- [Supabase Swift Auth](https://supabase.com/docs/reference/swift/auth-api)
- [Supabase Google login](https://supabase.com/docs/guides/auth/social-login/auth-google)
- [Supabase Apple login](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [Supabase mobile deep linking](https://supabase.com/docs/guides/auth/native-mobile-deep-linking?platform=swift)
