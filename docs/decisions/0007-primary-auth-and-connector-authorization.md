# ADR 0007: Separate product identity from connector authorization

- Status: Accepted
- Date: 2026-08-31

## Context

Founder's Office needs one account across Mac, iPhone, Windows, and Android. It may also connect several accounts from the same provider, such as two Google accounts. Connector credentials and product identity have different trust, recovery, and deletion requirements.

Composio accepts an application-supplied user identifier and stores connected provider accounts under that identifier. It does not replace the product's sign-in, session, workspace membership, or account-recovery system.

## Decision

Use two separate layers:

1. A standards-based identity provider authenticates the customer. The backend issues an opaque `FounderAccountID` and `WorkspaceID`.
2. Composio may broker selected connector grants. Every grant is keyed to the opaque account and workspace IDs, never an email address or display name.

Do not build passwords, password resets, session rotation, or account recovery in this repository. Select a managed OpenID Connect provider after the threat model, legal entity, production domain, and account-deletion flow are approved.

Each connected account has its own immutable connection ID, provider account ID, scopes, health, last successful cursor, pause state, and erase state. A job must pin the exact connection ID that it may use. “Use Google” is not sufficient when a customer has two Google accounts.

## Consequences

- A Composio outage cannot lock the customer out of Founder's Office.
- Removing a connector does not delete the Founder's Office account.
- Deleting the Founder's Office account revokes and erases every connector mapping.
- CloudKit may remain an Apple-beta sync transport, but it is not the future cross-platform identity authority.
- Connector access stays optional and least-privileged.

## Privacy and security

The app stores refreshable credentials only in an approved Keychain or server-side secret store. Logs contain opaque correlation IDs, never tokens, emails, provider account names, or message content. Reauthentication, scope expansion, account switching, and destructive actions require an explicit customer decision.

## Migration and rollback

Introduce product identity before Windows or Android. Migrate Apple-beta workspaces by asking the signed-in customer to claim one local or iCloud workspace. Keep the original data read-only until the claim is verified. If connector authorization is disabled, local Moves, calendar reading, and manual Share/Paste capture continue to work.

## Related work

- [Trusted assistant architecture](../product/ASSISTANT_ARCHITECTURE.md)
- [Composio authentication model](https://docs.composio.dev/docs/authentication)

