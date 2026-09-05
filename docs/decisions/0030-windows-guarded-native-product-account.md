# ADR 0030: Guarded native Windows product account

- Status: Accepted
- Date: 2026-09-05
- Extends: ADR 0027, ADR 0028, and ADR 0029

## Context

Native Windows account wiring can be implemented before the backend callback receives explicit approval.
Configuration validation and protocol forwarding must not masquerade as working Google login or cross-device sync.
The installed app also needs a reliable setup location and an explicit workspace choice.

## Decision

1. Read the strict public configuration from the installed package's `ApplicationData.Current.LocalFolder`.
2. Expose that folder through an explicit native action. Do not guess Windows user paths or package identifiers.
3. Construct auth, Credential Locker, and browser services only when a separately compiled approval matches the full public configuration fingerprint.
4. Keep the approval absent until Main integration confirms the exact beta project and development callback allowlist entry.
5. Permit no runtime file, environment variable, or interface toggle to self-certify registration approval.
6. Scope refresh-session storage to development identity and the exact reviewed public configuration. Do not migrate unscoped entries automatically.
7. Use one cancellable browser attempt with a ten-minute deadline and same-process, single-use callbacks.
8. Require secure-session read-back before publishing signed-in state. Keep access tokens and verifiers in memory.
9. Keep product sign-in independent from explicit claim, attachment, manual Move sync, and Calendar consent.
10. Require a reviewed name and confirmation before claiming local data. Block data-bearing attachment pending export-and-replace review.
11. Keep quarantined conflicts authoritative across repository relaunch and block same-Move pull replacement until review.

The local interface displays the remote workspace ID for exact, private cross-device comparison.
A completed request drain does not prove native Mac-to-Windows convergence.
Unsupported workspace entities remain a fail-closed implementation gate.

## Consequences

The native code paths and synthetic lifecycle tests can mature without enabling live network authorization.
A valid setup file does not unlock Google sign-in. The current approval remains absent.
Public-key rotation or a project change requires another review and a fresh scoped session.
Product account, Move sync, and Windows Calendar statuses remain separate. Mac calendar configuration is unchanged.

## Verification

Synthetic tests cover approval mismatches, browser refusal, duplicate starts, invalid callbacks, cancellation, deadline expiry, and secure read-back failure.
Repository tests reopen the canonical database and prove conflicts still block networking and pull replacement.
Native API compilation and hosted Windows packaging do not replace physical laptop testing.
Only actual Windows Google sign-in and exact synthetic workspace roundtrip can satisfy the remaining live acceptance gate.
