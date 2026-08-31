# 0014 — Signed external Mac update channel

- Status: Accepted
- Date: 2026-08-31

## Context

The direct-download Mac beta needs staged updates and rollback evidence. The customer app is sandboxed, forbids temporary-exception entitlements, and must not modify installed code. A mutable “latest” URL or an unsigned version response could redirect customers to unreviewed bytes. Bundling a general-purpose updater would also broaden the privileged release surface before the core product is stable.

## Decision

Founder’s Office uses a small, application-owned update channel:

- Release builds embed one exact credential-free HTTPS feed URL, an explicit `beta` or `stable` channel, and one 32-byte Ed25519 public key. A client rejects a valid signature for the other channel even when both channels share an origin or key.
- The feed is a bounded JSON envelope. Its signature covers the exact manifest bytes.
- The signed manifest names a monotonic feed sequence, one exact immutable same-origin artifact URL, its SHA-256, byte size, sealed release evidence, rollout phases, pause state, and optional typed rollback evidence. The app persists the highest accepted sequence and exact payload digest to reject replay or sequence reuse after first trust.
- Replay state is scoped by a local SHA-256 namespace over the exact feed URL, channel, and public key. The URL and key never appear in preference keys or diagnostics. A reviewed channel move or signing-key rotation therefore starts a separate sequence history instead of inheriting a stale higher sequence.
- Automatic checks begin only after runtime readiness and completed onboarding, and run at most once per 24 hours. A manual check may enter a rollout early; a paused release never opens.
- The network client uses an ephemeral session, rejects every redirect, accepts only the configured URL and JSON response, and limits headers, body size, connections, and time.
- The app opens the exact signed artifact page in the default browser after consent. It never downloads, installs, replaces, or executes code.
- Alerts are owned by the notch transient-presentation coordinator, so an open notch suspends and restores only after the final alert outcome.
- The offline signer accepts the private key only from a non-synchronizing macOS Keychain item or bounded standard input. It never accepts private key material through arguments or environment variables and refuses output replacement.
- Release packaging and independent verification require the feed URL, public key, and sandbox network-client entitlement. The signing private key is not part of the source repository or app bundle.

## Consequences

The beta gets signed staged rollout and withdrawal controls without a self-updating privileged component. Customers still perform the normal browser download and signed-app replacement. A future updater would require a new security review and an ADR that supersedes this one.

Sparkle is not used for this beta. Its sandboxed installer path requires temporary-exception mach-service entitlements that conflict with the project’s explicit release policy. This decision is about the current entitlement and threat model, not a general rejection of Sparkle.

## Privacy and security

Checks send only a normal HTTPS request to the configured release origin. The deterministic rollout bucket is calculated locally from a random installation identifier and signed rollout ID; the identifier is not transmitted. Diagnostics contain only finite update operation names, outcomes, error domain/code, and timing buckets. They never contain URLs, workspace content, account data, or feed bodies.

Compromise of the hosting origin alone cannot create an accepted manifest without the offline private key. Compromise of the private key requires pausing the feed, withdrawing affected downloads, rotating the public key in a newly signed/notarized app build, and publishing incident evidence.

## Migration and rollback

Development builds have empty update configuration and fail closed. The first direct beta must freeze the production origin and public key before archive creation. Withdrawing a bad release means publishing a newly signed paused envelope. Corrective software always uses a higher Apple build number; the app never performs a downgrade. A rollback manifest names the older affected build and an incident ID as evidence while directing customers to the newer corrective build.

## Related work

- [Mac direct-distribution runbook](../product/MAC_DIRECT_DISTRIBUTION.md)
- [Signed update-channel runbook](../product/MAC_SIGNED_UPDATE_CHANNEL.md)
- [Paid-beta launch gates](../product/LAUNCH_GATES.md)
