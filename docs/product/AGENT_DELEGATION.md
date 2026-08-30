# Agent delegation product contract

## Customer promise

“Make Codex do it” and “make Claude do it” start a real, bounded job under the customer's saved workspace policy. Founder’s Office always says where the job runs and where it can be reviewed.

It does not disguise terminal output as product activity, claim that a local SDK job exists in another app, or expose private model reasoning.

## Entry points

The global navigation stays Home, Moves, Calendar, and Settings.

1. A Move's action menu contains **Delegate…**.
2. The command palette accepts an instruction such as “Make Codex research this Move” or “Make Claude draft the launch brief.”
3. A future voice/App Intent uses the same command contract.

When provider, Move, workspace, and saved permissions are unambiguous, the explicit imperative is authorization to start within that policy. Otherwise Founder’s Office opens a short plan-and-access preview. It never silently widens access.

## Glanceable notch state

Only one compact strip is added to Home while a job is active:

```text
Codex · Editing · 2m                         View   Stop
Claude · Needs approval                            View
```

The strip uses native controls, full-row hit targets, clear hover/pressed states, and the existing typography and frosted surface. Closing the notch does not stop the job.

## Agent Workspace

Detailed execution opens in a regular macOS window with four stable sections.

### Activity

Human-readable observable events: planning, reading a named source, running an approved tool, editing, testing, waiting for input, and preparing review. Raw provider events are available behind a disclosure for support, with secrets redacted.

### Context

- Move and instruction supplied by the customer;
- selected workspace and policy;
- files, instructions, and sources the agent actually opened;
- tools and network domains actually used;
- provider, model, session reference, elapsed time, and cost when available.

This answers “How did it know what to do?” without exposing hidden chain-of-thought.

### Changes

Changed and created files, a reviewable diff, tests and their outcomes, generated artifacts, warnings, and an unchanged-files statement when no edits were made.

### Result

A rendered result with actions that make the work usable:

- Review changes
- Open result
- Reveal in Finder
- Open project
- Copy
- Attach to Move
- Continue with feedback
- Accept result
- Mark Move Done (separate and always explicit)

## Provider behavior

| Choice | Start mechanism | Where the customer watches | What Founder’s Office can show |
|---|---|---|---|
| Codex | Persistent app-server thread through the local helper | Agent Workspace; open the selected workspace in Codex | Live events, plan, approvals, diff, tools, result, session ID |
| Claude cloud | Customer-owned Claude Code Routine API | Genuine Claude cloud session plus a Founder’s Office launch record | Started/session link; no invented live status |
| Claude local | Claude Agent SDK through the local helper | Agent Workspace | Live events, approvals, diff, checkpoints, result and supported usage data |

Codex app-server is the rich-client integration surface. It owns authentication and persistent thread history. Founder’s Office names each thread from the Move and opens Codex with the selected project. An exact “Open this thread” control stays hidden until OpenAI documents a supported exact-thread route.

Claude's Routine trigger returns a real cloud-session reference, so “Open in Claude” is honest. A local Claude Agent SDK session is separate from Claude Desktop history; the UI therefore says **Claude local agent** and keeps review in Founder’s Office.

## Safety and distribution

- No local provider process in the App Store target.
- Local execution uses a Developer ID-signed and notarized helper with authenticated IPC.
- One user-selected workspace per job; reject symlink and path escapes.
- Default-deny commands, tools, network domains, and external effects beyond the saved policy.
- Approval cards show the exact command, write scope, or network domain.
- Stop terminates the complete process group and records a content-free canceled event.
- Prompts, paths, transcripts, diffs, outputs, artifacts, commands, provider events, and session URLs never enter analytics, diagnostics, or the sync envelope.
- Provider tokens live in Keychain or provider-owned storage.
- App restart restores job state and reconciles it with the helper or cloud session.

## Delivery slices

1. Provider-neutral job store, synthetic adapter, Agent Workspace, retention controls, and truthful briefing fallback.
2. Codex app-server helper: one selected git workspace, one job, persistent named thread, plan, approval, cancel, diff, tests, result, and open-workspace handoff.
3. Claude cloud Routine adapter with Keychain token and real session link.
4. Claude local Agent SDK adapter behind the same helper contract.
5. iPhone read-only status and approval notifications after Mac execution is reliable; no CloudKit-based remote command runner.

## Acceptance criteria

- The same views and lifecycle support Codex and Claude.
- A job starts from the explicit phrase when saved scope is sufficient; first use and wider access require preview.
- Every state survives app restart.
- The customer can identify context supplied, context used, tools used, sources used, changes, evidence, and artifacts.
- Every result has at least one usable open, copy, reveal, attach, or diff action.
- Provider-app visibility is stated accurately and unsupported handoffs are absent.
- Accepting a result and completing a Move remain separate actions.
- App Store builds contain no arbitrary local executable runner.
- VoiceOver, keyboard navigation, Reduce Motion, Increase Contrast, and Reduce Transparency are covered.
