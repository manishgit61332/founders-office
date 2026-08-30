# Contributing

This is a private product repository. Changes should be small, reviewable, and safe for customer data.

## Workflow

1. Create an issue describing the outcome, risk, and acceptance criteria.
2. Create a branch from `main` using `codex/<short-name>` or `feature/<short-name>`.
3. Use Conventional Commit prefixes.
4. Update `CHANGELOG.md` for customer-visible behavior.
5. Add or supersede an ADR when the change creates a durable architecture, privacy, data, or product-language decision.
6. Run:

   ```bash
   Scripts/check-repository-safety.sh
   Scripts/ci-checks.sh
   ```

7. Open a pull request and complete every applicable verification field.

## Privacy boundary

Use synthetic fixtures in source and screenshots. Never attach a real workspace, task title, calendar event, account, communication, selected photo, OAuth token, support bundle, or Codex run to an issue or pull request.
