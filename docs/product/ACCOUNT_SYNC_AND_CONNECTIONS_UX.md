# Account, sync, and connections UX

## Product decision

Founder’s Office has three separate trust layers:

1. **Google sign-in proves identity.** The app asks only for `openid`, `email`, and `profile` during account creation.
2. **Founder’s Office owns the workspace and sync.** Its backend maps Google’s stable issuer and subject claims to opaque `FounderAccountID` and `WorkspaceID` values, then synchronizes revisioned task records.
3. **Composio brokers optional connections.** Notion, Gmail, Drive, and other grants are attached to the opaque Founder’s Office account. A connector outage must never prevent sign-in or access to Moves.

Google sign-in is not task storage. Composio is not product authentication. ChatGPT, Codex, Claude, and other AI workers are not presented as ordinary OAuth connections.

This contract extends [ADR 0007](../decisions/0007-primary-auth-and-connector-authorization.md) without enabling a production identity provider or connector by itself.

## Experience principles

- Ask for one decision at a time.
- Do not show an integration catalog during onboarding.
- Let a person use one Mac without creating an account.
- Explain the benefit before requesting access.
- Request the minimum scope at the moment it becomes useful.
- Keep connected accounts visible, named, pausable, and revocable.
- Require a preview and explicit approval before any external send, publish, delete, purchase, or permission change.
- Never use email, display name, or a Composio user ID as the workspace tenancy key.

## First-run flow

The first screen has one promise and two actions:

> **Your office, on every device.**  
> Keep your Moves, goals, and preferences with you.

- **Continue with Google** — primary action.
- **Use this Mac only** — quiet secondary action.

No Calendar, Gmail, Notion, Drive, Claude, Codex, or Composio choice appears here.

After Google succeeds:

1. A new customer enters a new empty workspace.
2. A returning customer restores the last workspace automatically.
3. A customer with more than one workspace chooses one from a short list.
4. A device with existing local Moves gets a migration decision before any upload or overwrite.

The migration choices are:

- **Move this Mac’s workspace into my account**
- **Keep both workspaces**
- **Review differences**

The app never silently merges two workspaces and never silently replaces local data.

After workspace resolution, onboarding continues with the first Move and notch rehearsal. Calendar and Launch at Login are requested contextually, after their value is visible.

## Settings information architecture

The top notch navigation remains unchanged. The gear opens **Settings**. The left rail remains four items:

1. **Account** — identity, workspace, sync status, devices, name, and vision image.
2. **Appearance** — the existing visual controls.
3. **Finish line** — the existing primary-goal controls.
4. **Calendar** — the existing local EventKit account view.

The Account page includes a compact Connections row. **Manage** opens a child page inside the same Settings surface; it does not add another permanent rail item.

### Signed-out Account state

- Title: **Keep your office with you**
- Detail: **Sign in once to restore your Moves on another device.**
- Primary action: **Continue with Google**
- Secondary text action: **Keep using this Mac only**

### Signed-in Account state

- Google avatar, actual account name, and email returned by the authenticated session.
- Workspace name and sync status such as **Saved just now**.
- **Manage devices** and **Sign out this Mac** actions.
- The greeting reads from the saved preferred name; it is never hard-coded.
- A device-session page supports **Sign out** per device and **Sign out all other devices**.

Transient states use calm, useful language:

| System state | Customer copy |
|---|---|
| Restoring session | Opening your office… |
| Uploading local edits | Saving 3 changes… |
| Offline with a local copy | Saved on this Mac · will sync when online |
| Revision conflict | Two versions need your review |
| Session revoked | Sign in again to keep syncing |

Do not display raw cursors, revision numbers, provider IDs, or vendor names in the primary UI.

## Connections without a wall of apps

Connections are disclosed in layers:

1. **Connected** — accounts already in use, with health and pause controls.
2. **Suggested for this Move** — at most two recommendations derived from a clear user action or current task.
3. **Browse all connections** — a searchable catalog behind a deliberate action.

The default catalog for the first paid version contains only Google Calendar, Google Drive, Gmail, and Notion. The product does not expose Composio’s raw catalog.

A contextual suggestion looks like this:

> **This Move mentions a Notion page.**  
> Connect Notion so Founder’s Office can open the right page when you work on it.

Actions: **Connect Notion** and **Not now**. Dismissal is remembered and does not create a red warning.

### Connection preflight

Before opening a provider consent screen, show one compact review sheet:

- **What it can read**
- **What it can change**
- **When it can run**
- **Which account it will use**

The sheet uses plain-language capabilities generated from an application-owned allowlist, not from model output. A connection can be paused, reauthenticated, disconnected, and erased independently.

OAuth runs in the system authentication session or browser. The notch holds an interaction lease while the flow is active, so moving the pointer to the provider window does not cancel the attempt. Returning to the app restores the same Settings route and shows success, cancellation, or a recoverable error.

## Multiple Google accounts

One Google account is the primary Founder’s Office identity. Additional Google accounts are optional resource connections.

Each connection stores:

- immutable connection ID;
- provider account ID;
- customer-facing alias such as **Work** or **Personal**;
- exact scopes and enabled tools;
- health, last successful cursor, pause state, and erase state.

The first time a second account is added, ask for an alias. Every workflow pins the exact connection ID. When more than one matching account exists, account selection is required; “use Google” is not enough. A consequential approval sheet always repeats the chosen account.

## AI workers are a separate product concept

The Connections screen has an **AI workers** entry point, not provider cards mixed with Notion and Calendar.

Each worker explains:

- where it runs;
- whose subscription or API credits it uses;
- which project or workspace it can access;
- whether it can continue in the background;
- what requires approval;
- where the result will appear.

Examples:

- **Founder’s Office AI** — product-managed, bounded assistance.
- **Codex** — starts a visible Codex task through an approved product integration when available; a consumer ChatGPT login is not an OpenAI API credential.
- **Claude Code** — starts a visible Claude Code task through an approved local or cloud integration when available; a Claude.ai subscription is not an Anthropic API credential.
- **Higgsfield** — use its supported API, MCP, or CLI account route if and when the product passes security review. Until then, show **Request connection**, not a fake Connect button.

## Backend contract

The client must not write one shared JSON blob to a generic cloud document. The production sync authority provides:

- an opaque account and workspace identity;
- one record per Move, goal, membership, and durable event;
- per-record revisions and a required `baseRevision` on mutation;
- stable operation IDs so retries are idempotent;
- an atomic event append plus revision advance;
- a local outbox for offline changes;
- a cursor-based change feed for restore and incremental sync;
- explicit conflict responses;
- encrypted transport, export, deletion, and an audit trail.

The native client sends a Google ID token to the backend over HTTPS. The backend verifies the signature, audience, issuer, and expiry, maps the stable issuer and subject to the Founder’s Office account, and issues a separate per-device Founder’s Office session. Native session material lives in Keychain.

Composio API keys and connector refresh credentials remain server-side. Composio receives the opaque Founder account ID, a toolkit allowlist, an exact tool allowlist, multiple-account mode, and required explicit account selection. Production OAuth uses Founder’s Office custom auth configurations and callback identity verification.

## Rollout

### Phase 1 — identity and safe workspace sync

- Make the transactional repository the only writer.
- Finalize the product domain, privacy policy, terms, support contact, bundle IDs, and Google Cloud development and production projects.
- Implement Google sign-in in the system authentication session.
- Implement backend token verification, device sessions, workspace restore, local-workspace claim, revisions, outbox, conflicts, export, and erase.
- Test new, returning, offline, revoked, second-device, local-migration, and cross-account cases.

### Phase 2 — calm Connections

- Add the nested Connections page and permission preflight.
- Start with Calendar, Drive, Gmail, and Notion only.
- Use custom branded OAuth configurations for production.
- Require exact account selection and approval-gate every external mutation.

### Phase 3 — AI workers

- Add one worker at a time behind a capability flag.
- Show visible task status, approval checkpoints, cost ownership, logs, outputs, and cancellation.
- Do not claim consumer-app access that the provider does not expose.

## Acceptance criteria

- A returning customer signs in on a new device and restores the correct workspace.
- A local workspace is never overwritten or merged without a named choice.
- One customer cannot address another customer’s workspace or Composio connections.
- Signing out one device does not erase the workspace.
- Account deletion revokes device sessions, erases connector mappings, and starts the documented data-deletion flow.
- Two Google connections require explicit selection and remain independently pausable and revocable.
- Onboarding contains no connector catalog and no broad data scopes.
- Settings shows actual account data and never a hard-coded name.
- Unsupported providers never display a working-looking Connect action.
- The core notch remains useful when signed out, offline, or when Composio is unavailable.

## Official references

- [Google OAuth for native apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google backend ID-token verification](https://developers.google.com/identity/sign-in/ios/backend-auth)
- [Google OAuth production policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [Composio authentication](https://docs.composio.dev/docs/authentication)
- [Composio multiple connected accounts](https://docs.composio.dev/docs/authentication/managing-multiple-connected-accounts)
- [Composio managed versus custom authentication](https://docs.composio.dev/docs/authentication/custom-app-vs-managed-app)
- [Composio session restrictions](https://docs.composio.dev/docs/configuring-sessions)

