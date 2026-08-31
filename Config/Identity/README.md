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
FOUNDER_OFFICE_AUTH_CALLBACK_SCHEME = ORGANIZATION_OWNED_SCHEME
```

The publishable key is intended for public clients, but it is still validated so a secret/service-role key cannot be embedded accidentally. Never place a Supabase secret key, service-role key, Apple private key, or OAuth client secret in the app or repository.

The callback URL registered in Supabase is:

```text
ORGANIZATION_OWNED_SCHEME://auth/callback
```

Configure the same scheme in the Google provider and enable the final Apple App ID for Sign in with Apple. The committed development scheme is provisional and cannot be used for a release.

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
