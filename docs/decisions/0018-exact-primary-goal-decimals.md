# 0018 — Exact bounded primary-goal decimals

- Status: Accepted
- Date: 2026-08-31
- Extends: ADR 0015 exact `numeric(30,8)` wire decision into local clients

## Context

Primary-goal progress was stored as binary `Double` values on Mac and iPhone.
The Mac editor then reopened every non-integer with one fractional digit. A
person could enter `3000.12345678`, persist a binary approximation, and see
`3000.1` on the next edit even though the public sync contract and Postgres use
exact `numeric(30,8)` values. This created a local/wire type mismatch before
authenticated sync was enabled.

Existing personalization JSON stores goal values as JSON numbers. Older Apple
clients decode those numbers as `Double`, so changing the JSON shape to an
object or string would break mixed-version reads. Existing in-contract integer
and fractional JSON also needs to migrate without exposing binary expansion
digits such as those behind `0.1`.

## Decision

1. Represent `PrimaryGoal.currentValue` and `targetValue` as `GoalDecimal?`.
   The type owns an exact Foundation `Decimal`, is nonnegative, permits at most
   eight meaningful fractional digits, and is bounded by
   `9999999999999999999999.99999999`.
2. Encode `GoalDecimal` as a JSON number, never a JSON string, object, or
   `Double`. Decode legacy JSON numbers directly into `Decimal` and validate
   the result before it enters canonical state.
3. Parse customer input with a complete decimal grammar. Allow a leading
   supported unit symbol, a trailing percent sign, and correctly grouped comma
   separators. Reject partial parses, exponents, negative values, non-finite
   values, malformed grouping, more than eight entered fraction digits, and
   out-of-range values without mutating the goal.
4. Use the exact canonical decimal text when reopening an editor. Display may
   add locale grouping and unit symbols but may not reduce the stored fraction
   to one digit. Conversion to `Double` is allowed only as a lossy projection
   for a bounded progress bar after both canonical values are validated.
5. Keep the existing personalization schema and version-1 JSON contract because
   the durable wire shape has not changed. The Swift source API intentionally
   changes from `Double?` to `GoalDecimal?`; Mac and iPhone consumers must ship
   this source update together.

## Consequences

- Mac, iPhone, SQLite snapshots, JSON projections, and local outbox records use
  the same exact numeric domain as the backend.
- Older clients can still read new JSON numbers, and the new type reads legacy
  integer and in-contract fractional numbers without binary artefacts.
- Trailing zeroes are canonicalized because they do not change the numeric
  value. All meaningful digits through scale eight survive edit and relaunch.
- A legacy value outside the frozen nonnegative `numeric(30,8)` domain cannot
  be preserved while also satisfying that domain. Such a snapshot fails closed
  into the existing recovery path; it is never silently rounded, clamped, or
  uploaded.

## Privacy and security

Validation runs before persistence and outbox creation. Error copy reports only
the violated numeric rule and never logs a customer-entered value. JSON decoding
rejects strings and non-finite values so alternate representations cannot bypass
the canonical type.

## Migration and rollback

Opening a legacy SQLite snapshot or JSON import decodes each numeric token
directly as a base-10 decimal. In-contract values need no schema rewrite and are
encoded in the same JSON-number shape on the next transaction. Unsupported
legacy values leave the canonical source untouched and require explicit recovery
or export with an older compatible build.

Rollback to a `Double` build remains JSON-compatible for values written by this
version, but loses the compile-time exactness guarantee and must not be used once
cross-platform sync is enabled.

## Verification

- Exact eight-place values round-trip through JSON, a primary-goal outbox
  operation, SQLite commit, and repository relaunch.
- Maximum magnitude, maximum scale, malformed input, JSON strings, non-finite
  values, negatives, and overflow have explicit acceptance or rejection tests.
- Legacy integers, fractions, exponent-form JSON numbers, and a JSONEncoder
  `Double` fixture migrate without invented visible precision.
- Mac and iPhone editors use canonical text rather than one-decimal formatting.

## Related work

- ADR 0010 — Serialized transactional workspace repository
- ADR 0015 — Supabase Auth and revisioned cross-platform sync
- ADR 0017 — Bounded local entity operation outbox
