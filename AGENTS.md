# Founder's Office repository instructions

- Treat `openloops.json`, `personalization.json`, `OPEN_LOOPS_CONTEXT.md`, photos, Codex runs, support bundles, and QA captures as private runtime data. They must never be committed.
- Keep customer-facing language as **Moves**. Legacy `OpenLoop`, `.waiting`, and filename identifiers remain internal compatibility names until a versioned migration.
- Use `Scripts/openloops.py` for local move-store updates when the runtime store exists. Never mark a move Done without evidence.
- Do not log task titles, calendar titles, names, message bodies, prompts, file paths, credentials, or tool output.
- Record customer-visible changes in `CHANGELOG.md`.
- Record durable architecture and product decisions as ADRs in `docs/decisions/`; accepted ADRs are superseded, not rewritten.
- Use Conventional Commit prefixes: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `security:`, and `release:`.
- Before committing, run `Scripts/check-repository-safety.sh` and `Scripts/ci-checks.sh`.
