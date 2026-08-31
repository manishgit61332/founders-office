# 0009 — Priority recategorization and a unified calendar agenda

- Status: Accepted
- Date: 2026-08-31

## Context

As a workspace grows, a deadline-only list does not always surface the most important Move. The product also showed app-owned deadlines in an Important Dates rail while the selected calendar day could incorrectly say that nothing was scheduled. Customers need a fast way to compare importance with urgency, reprioritize without opening a form, and see one truthful day agenda.

The Move schema already has four durable priority values (`P0` through `P3`) but no manual sort rank. EventKit is the source of truth for calendars already enabled on the device, while Founder’s Office remains the source of truth for Move deadlines.

## Decision

1. Present active Moves through two interchangeable lenses: **Priority** and **Due**.
2. Preserve all four stored priority levels and label them Critical, High, Medium, and Low. Use red, orange, blue, and neutral side rails together with text labels, so color is not the only signal.
3. A drag between priority lanes changes only the Move’s priority. It does not imply manual ordering, status changes, or deadline changes.
4. Use UUID-only drag payloads. Menu, planning-editor, keyboard, and accessibility alternatives remain available.
5. Build a selected-day agenda by composing, not copying, active Move deadlines with EventKit events. Move deadlines are never inserted into EventKit merely to appear in Calendar.
6. App-owned deadlines remain visible without Calendar permission. External events and event creation require full EventKit access.
7. New events are written to a customer-selected writable EventKit calendar. The picker identifies provider, account, and calendar so two Google accounts remain distinguishable.
8. Priority and deadline changes advance only their field-level merge clocks. They do not advance the whole-Move clock used for status, completion, deletion, title, and details conflicts.

## Consequences

- Customers can switch between importance and urgency without changing global navigation.
- An empty priority lane must remain available as a drop target.
- Manual within-lane ordering remains unsupported until the schema gains a versioned, merge-safe rank field.
- A stale offline planning edit can merge with a newer completion or deletion without replacing that newer lifecycle state.
- The same Move may appear in Moves and Calendar because they are different views of one record; it must not appear twice within the selected Calendar day.
- Multi-day external events require interval-overlap filtering, not a start-date-only comparison.

## Privacy and security

- Drag payloads contain only Move UUIDs, never titles or details.
- Calendar event titles, account names, and calendar names are not written to diagnostics.
- Preview and snapshot builds use synthetic calendars and never read or write the customer’s EventKit database.
- EventKit performs provider sync and authorization; Founder’s Office does not store Google credentials.

## Migration and rollback

No data migration is required. Existing `P0` through `P3` values remain unchanged; only the customer-facing `P2` label changes from Normal to Medium. Rolling back the views leaves all stored priority and deadline data intact.

## Related work

- ADR 0003 — Moves and Blocked language
- ADR 0004 — Approval-gated connectors
- ADR 0007 — Product identity and connector authorization
