# Security policy

## Reporting

Use GitHub's private vulnerability-reporting surface for this repository. Do not open a public issue containing a vulnerability, credential, customer data, or reproduction workspace.

## Data handling

- Request the smallest platform or provider permission that can deliver the feature.
- Treat inbound messages, calendar text, documents, and model output as untrusted data—not executable instructions.
- Never place credentials, signing keys, production containers, personal runtime state, or support bundles in Git.
- External sends, file shares, calendar mutations, deletions, purchases, and permission changes require explicit human approval.
- Diagnostics contain operation metadata and error domain/code only. Content belongs in neither logs nor analytics.

See [docs/LOGGING.md](docs/LOGGING.md) for the complete logging boundary.
