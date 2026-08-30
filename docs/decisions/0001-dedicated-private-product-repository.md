# ADR 0001: Dedicated private product repository

- Status: Accepted
- Date: 2026-08-30

## Context

The local parent workspace contains founder operations, research, media, and unrelated business material alongside the application. Publishing that parent directory would create an unnecessary privacy and intellectual-property risk.

## Decision

The `OpenLoops` application directory is the root of a dedicated private GitHub repository named `founders-office`. Runtime state, personal media, QA captures, audits, builds, credentials, signing files, support bundles, and exports are excluded.

## Consequences

- Product code and engineering history have a clean boundary.
- Founder operating files remain local and outside this Git history.
- Any screenshot intended for documentation must be synthetic, manually reviewed, and copied into an explicitly tracked documentation-assets directory.

## Privacy and security

Repository safety checks fail when known runtime, credential, or oversized files are tracked.

## Migration and rollback

No prior commits or remote existed. The parent Git metadata is left untouched and is not used or pushed by this product repository.
