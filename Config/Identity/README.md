# Product identity configuration

Founder’s Office remains fully usable in local-only mode when this configuration is absent. Product sign-in is separate from Calendar, Google account, Gmail, Notion, Composio, or assistant connector authorization.

The Apple clients use Supabase Auth with:

- Google through OAuth and PKCE in `ASWebAuthenticationSession`;
- native Sign in with Apple through `AuthenticationServices` and a one-time nonce;
- session persistence in an app-specific Keychain service;
- a token-free account summary for UI and diagnostics.

## Required public build values

Supply these as Xcode build settings for a configured build:

```text
FOUNDER_OFFICE_SUPABASE_URL = https://PROJECT_REF.supabase.co
FOUNDER_OFFICE_SUPABASE_PUBLISHABLE_KEY = sb_publishable_...
FOUNDER_OFFICE_AUTH_CALLBACK_SCHEME = founders-office
```

The publishable key is intended for public clients, but it is still validated so a secret/service-role key cannot be embedded accidentally. Never place a Supabase secret key, service-role key, Apple private key, or OAuth client secret in the app or repository.

The provisional custom callback registered in Supabase is:

```text
founders-office://auth/callback
```

The client callback allowlist accepts that provisional scheme,
`founders-office-dev://auth/callback` for local development, or an HTTPS
universal link ending in `/auth/callback`. It rejects all other schemes,
including `javascript`, `file`, `data`, and `http`, as well as callbacks with
credentials, query strings, fragments, or a different route. A production
universal link still requires an organization-owned domain, associated-domain
entitlements, and an exact redirect registration. The committed custom schemes
are provisional and cannot be used for a release without review.

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

Only the selected path may start the sync outbox. Switching accounts never reuses another account’s workspace binding.

## External setup still required

Before a distributable beta, the product owner must provide the organization-owned domain, bundle IDs, callback scheme, Apple App ID/capability, Supabase project, Google OAuth credentials, and Apple provider configuration. RLS and RPC migrations must be deployed and their pgTAP suite must pass against that exact project.

References:

- [Supabase Swift Auth](https://supabase.com/docs/reference/swift/auth-api)
- [Supabase Google login](https://supabase.com/docs/guides/auth/social-login/auth-google)
- [Supabase Apple login](https://supabase.com/docs/guides/auth/social-login/auth-apple)
- [Supabase mobile deep linking](https://supabase.com/docs/guides/auth/native-mobile-deep-linking?platform=swift)
