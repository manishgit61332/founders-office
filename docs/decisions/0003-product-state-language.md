# ADR 0003: Product state language

- Status: Accepted
- Date: 2026-08-30

## Context

“Open Loops” feels borrowed, and “Waiting” combines several different reasons work cannot advance.

## Decision

Use **Moves** in customer-facing navigation. Use **Blocked** for a move the founder owns but cannot advance because of a named dependency. Add **Awaiting reply** later for work another person or system owes. Use **Needs You** as a computed attention queue for judgment or approval. Reserve **Bottleneck** for insight across multiple moves.

Internal `OpenLoop`, `.waiting`, and JSON identifiers remain until a versioned migration is designed and tested.

## Consequences

Customer language becomes clearer without risking existing workspace decoding.

## Privacy and security

No impact.

## Migration and rollback

The current change is display-only. A future schema migration must dual-read legacy values and preserve backups.
