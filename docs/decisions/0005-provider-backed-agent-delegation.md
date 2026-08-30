# ADR 0005: Provider-backed agent delegation with truthful review surfaces

- Status: Accepted
- Date: 2026-08-31

## Context

The prototype launches an ephemeral `codex exec` process and shows only a final text file. The job is not resumable, does not expose approvals, provenance, changes, or artifacts, and cannot be found reliably in the Codex app. Adding a second hidden process for Claude would repeat the same problem.

Customers need to say “make Codex do it” or “make Claude do it,” see where the task is running, understand what context and tools it used, review the result, and continue in the provider's product when that provider officially supports it.

## Decision

Use one provider-neutral `AgentJob` lifecycle and a dedicated Agent Workspace review window.

- **Codex:** use Codex app-server through a separately distributed local helper. Start a persistent named thread, stream structured activity, approvals, plans, diffs, and results into Founder’s Office, and open the selected workspace in Codex. Exact-thread handoff appears only if OpenAI provides a documented supported route.
- **Claude cloud:** trigger a customer-created Claude Code Routine. Store its token in Keychain, retain the returned session reference locally, and open the genuine Claude cloud session for review.
- **Claude local:** use the Claude Agent SDK through the same local-helper boundary. Founder’s Office owns the activity, approval, diff, and artifact UI because local SDK sessions are not Claude Desktop sessions.

The fixed notch navigation remains Home, Moves, Calendar, and Settings. Delegation starts from a Move, an explicit natural-language command, or a command palette; it does not become a fifth global tab. The expanded Agent Workspace is a normal macOS window rather than a dense notch screen.

An explicit imperative naming a provider may start immediately only when the user has already selected that workspace and saved an adequate policy. First use, ambiguous scope, or a wider capability request opens a plan-and-access preview. Sending, publishing, deleting, purchasing, changing access, or representing the customer remains separately approval-gated.

## Consequences

The existing hidden `CodexRunner` is a development prototype, not the shipping agent architecture. Provider adapters share state, review, cancellation, retention, and safety behavior without provider-specific view branches.

The Agent Workspace shows observable evidence rather than hidden reasoning:

- context supplied to the agent and files or sources it actually opened;
- the human-readable plan and current observable action;
- tools and approved permissions used;
- files changed, diff, tests, artifacts, warnings, elapsed time, and cost when supplied;
- usable actions such as review changes, open result, reveal in Finder, open project, attach to Move, continue with feedback, cancel, and accept result.

Accepting an agent result never marks the originating Move Done. Continued work and retries create a new attempt linked to the previous one.

## Privacy and security

Only a content-free job envelope may sync: opaque identifiers, provider, execution state, timestamps, and counts. Prompts, transcripts, paths, diffs, provider events, artifacts, commands, source contents, session URLs, and credentials remain in a local encrypted job vault with visible retention and erase controls. Diagnostics remain content-free.

The App Store target does not execute arbitrary local processes. Local Codex and Claude execution requires a Developer ID-signed and notarized helper, authenticated IPC, a user-selected workspace, path-escape protection, cancellation of the full process tree, and a policy that denies unapproved external effects. Provider credentials remain provider-owned or in Keychain. Founder’s Office does not scrape provider databases, tokens, histories, or private deep links.

## Migration and rollback

Introduce the provider-neutral model and synthetic Agent Workspace first. Replace `CodexRunner` only after the helper passes isolation, approval, cancellation, restart-recovery, privacy, and signing checks. Until then, release builds offer a truthful “copy briefing and open provider” fallback. Each provider adapter remains capability-gated and can be disabled independently without affecting Moves.
