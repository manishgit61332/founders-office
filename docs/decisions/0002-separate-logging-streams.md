# ADR 0002: Separate logging streams

- Status: Accepted
- Date: 2026-08-30

## Context

Diagnostics, a user-visible activity history, analytics, and source history have different audiences, retention rules, and privacy risks.

## Decision

Use Git/CHANGELOG/ADRs for engineering evidence, Apple Unified Logging for redacted local diagnostics, a future user-owned append-only ledger for product activity, and separate opt-in aggregate analytics.

## Consequences

The app cannot quietly reuse message, task, calendar, prompt, or diagnostic content for analytics. Support export and the activity ledger require explicit product work before launch.

## Privacy and security

Diagnostics contain operation metadata and error domain/code only. Content and paths are forbidden.

## Migration and rollback

Legacy `NSLog` calls are replaced with category-based `Logger` calls. Reverting does not require a data migration because no new persisted log store is created.
