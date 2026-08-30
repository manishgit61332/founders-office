# Logging and evidence policy

Founder's Office uses separate records for separate jobs. They must not be merged into one stream.

## 1. Engineering history

- Git commits explain code changes.
- `CHANGELOG.md` explains customer-visible changes.
- ADRs explain durable decisions and trade-offs.
- GitHub issues and milestones track product work.
- Release records capture verification and rollback evidence.

Commit messages use `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `security:`, or `release:`.

## 2. Runtime diagnostics

Apple Unified Logging is the only diagnostic sink in the current app. Categories describe the subsystem; messages describe the operation and result.

Allowed:

- operation name;
- success/failure state;
- duration and count;
- error domain and numeric code;
- app/build/schema version;
- random or one-way-hashed correlation identifiers.

Forbidden:

- task, calendar, message, email, file, workspace, or account text;
- names, addresses, photos, phone numbers, or recipient details;
- prompts, model responses, tool output, or copied documents;
- paths, filenames, credentials, tokens, cookies, or signing material.

Do not log `localizedDescription`; it can contain a customer path or name. Diagnostics remain local unless the user explicitly exports a redacted support bundle.

## 3. Product activity history

The future activity ledger is user-owned product data, not a diagnostic log. It must be append-only, transactional with the state mutation, exportable, erasable, and optionally synced through the customer's private workspace.

Minimum fields:

```text
eventID, timestamp, actor, action, entityType, opaqueEntityID,
outcome, revision, approvalState, correlationID,
appVersion, buildVersion, schemaVersion
```

It must not contain message bodies, prompts, tool output, task titles, or credentials.

## 4. Analytics

Analytics are opt-in and aggregate. They may contain approved event names and counts only. Diagnostic and activity payloads are never repurposed as analytics.

## AI and tool execution

Future jobs record the proposed action, allowed tool, approval decision, execution state, outcome, and rollback reference. They do not record the full prompt or source content. A job reaching `review_ready` never marks the founder's Move Done automatically.
