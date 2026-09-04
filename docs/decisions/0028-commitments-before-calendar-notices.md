# 0028 — Commitments before calendar notices

- Status: Accepted
- Date: 2026-09-04

## Context

Home previously selected the unfinished event with the earliest start time.
An all-day public holiday starts at midnight, so it could hide the next meeting.
The user wants personal events first, ordered by time, with public holidays last.

## Decision

1. Exclude events whose end is at or before the current time.
2. Select personal commitments before calendar notices, across the existing 30-day feed.
3. Compare eligible local days first. Treat an ongoing event as a candidate for today.
4. Within that day, select timed events before personal all-day events.
5. Order equal categories by start, end, then stable input position.
6. Leave the full Calendar feed unchanged.

The EventKit adapter treats subscribed, birthday, and read-only calendars as reference sources.
An all-day event from such a source is a calendar notice unless the current user organizes or attends it.
Timed events remain commitments, including events on read-only calendars.
Personal all-day events today still precede timed events tomorrow.

## Consequences

This is a presentation rule, not proof of authorship or a holiday-name classifier.
A read-only shared all-day entry without participant metadata falls into the notice category.
A holiday copied into a writable personal calendar remains a personal all-day event.
Provider metadata cannot reliably distinguish that copy from a deliberate personal commitment.
No event-title matching or private EventKit API is permitted.

## Privacy and security

The rule uses the existing Calendar permission and local metadata.
It sends no event content to a server or model and adds no diagnostic content.
It does not change provider calendars, events, credentials, or workspace data.

## Migration and rollback

No persisted schema or sync contract changes are required.
Reverting the presentation rule restores chronological selection without changing any events.

## Related work

- ADR 0009 — Priority recategorization and a unified calendar agenda
- [Apple: subscribed calendars](https://developer.apple.com/documentation/eventkit/ekcalendar/issubscribed)
- [Apple: identifying the current participant](https://developer.apple.com/documentation/eventkit/ekparticipant/iscurrentuser)
