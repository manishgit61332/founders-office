# ADR 0028: Windows public beta configuration

- Status: Accepted
- Date: 2026-09-05
- Extends: ADR 0027

## Context

An approved beta project can provide public client configuration before Windows callback registration and native activation exist.
The client needs to validate these values without implying live sign-in or workspace convergence.

## Decision

1. Stage public values in the ignored `Apps/Windows/Configuration/ProductAuth.local.json` file.
2. Require schema version 1 and exactly `schemaVersion`, `supabaseURL`, `publishableKey`, and `callbackURL`.
3. Fix the development callback to `founders-office-dev://auth/callback`.
4. Reject malformed, oversized, duplicate, unknown, linked, or secret-bearing configuration before constructing a network client.
5. Validate configuration and transient PKCE preparation through a separate offline acceptance tool.
6. Keep configuration loading separate from callback approval, native activation, sign-in, and workspace provisioning.
7. Exclude the local file from tracked content and development bundles.

Main integration owns registration approval. Windows acceptance must prove Google sign-in and exact synthetic workspace convergence.
Do not infer either result from a valid configuration file or a registered Mac callback.

## Consequences

Developers can prepare the Windows adapter without copying secrets or contacting the beta project.
The shipped app remains local-only. Production identity, native activation, and live acceptance remain separate gates.
Errors and preflight output contain stable codes only, without configuration values, paths, or transient authorization material.
The existing session and Calendar boundaries from ADR 0027 remain unchanged.

## Verification

Unit tests cover strict configuration parsing, bounded file loading, malformed key payloads, and exact callback matching.
Synthetic CI runs the offline preflight. Archive attack tests reject local configuration in the outer ZIP and nested MSIX.
The [acceptance guide](../../Apps/Windows/docs/public-configuration-and-sync-acceptance.md) defines the outstanding native checks.
