# Trusted assistant architecture

## Promise

Founder's Office watches only what a customer explicitly connects, finds the next meaningful move, prepares the work, and asks before it acts.

It is not a miniature inbox, a private-app scraper, or an invisible autonomous sender.

## Vocabulary

- **Move:** work the founder has committed to.
- **Blocked:** the founder owns the move, but a named dependency prevents progress.
- **Awaiting reply:** another person or system owes the next action; this future state requires an owner and follow-up date.
- **Needs You:** a computed queue where the assistant prepared something but needs judgment, approval, credentials, or a physical action.
- **Bottleneck:** an insight across several moves, never a Kanban state.

Commitment lifecycle, readiness, and automation execution remain separate:

```text
lifecycle: inbox | next | doing | awaiting_reply | done | archived
readiness: ready | needs_user | blocked | scheduled
execution: not_requested | triaging | draft_ready | awaiting_approval |
           queued | running | review_ready | succeeded | failed | canceled
```

AI reaching `review_ready` never marks the customer's Move Done.

Provider-backed execution follows the shared lifecycle in [Agent delegation product contract](AGENT_DELEGATION.md). Codex uses its rich-client app-server surface; Claude uses either a genuine cloud session or a local agent whose review UI remains in Founder's Office. Provider-app handoff is shown only when the provider supplies a supported route.

## Processing pipeline

```text
explicitly connected source
→ provider event pointer or OS change
→ cursor and deduplication
→ deterministic relevance rules
→ on-device classification when needed
→ cloud reasoning only for uncertain or complex work
→ suggested Move / Needs You / Blocked state
→ policy and permission check
→ preview → approve, open, copy, or dismiss
```

Inbound communication is untrusted data, not an instruction. The policy engine—not the model—controls tools and external effects.

## Connector boundary

| Source | Supported product route |
|---|---|
| Apple and device calendars | EventKit plus store-change notifications |
| Multiple Google Calendar accounts | EventKit locally; Google webhooks only for optional always-on mode |
| Gmail | OAuth, push notifications, and history cursor after verification work |
| Google Drive | Google Picker and per-file `drive.file` access |
| Outlook / Microsoft 365 | Delegated Graph permissions and change notifications |
| Personal WhatsApp | Explicit Share, Forward, or Paste; never passive local-database or notification scraping |
| WhatsApp Business | Official Cloud API and webhooks after Meta review |
| Apple Mail / iMessage | Limited platform-specific compose/extension flows; no promise of complete inbox access |

Two accounts from the same provider are independent connections keyed by provider, provider account ID, and resource ID. Each has separate credentials, scopes, filters, cursors, health, pause, disconnect, and erase controls.

## Action levels

| Level | Capability | First paid version |
|---|---|---|
| 0 | Observe, deduplicate, classify | May run automatically |
| 1 | Create/update a local Move, reminder, summary, or draft | Opt-in and reversible |
| 2 | Prepare a message, file share, or calendar change | Always appears in Needs You |
| 3 | Send, publish, delete, spend, or change access | Never automatic in v1 |
| 4 | Legal, financial, healthcare, or security representation | Always manual and strongly gated |

## Credit efficiency

Basic sync consumes no model credits.

1. Provider cursors, allowlists, labels, exact dates, attachment types, and deduplication use no model.
2. A small on-device model classifies only likely new candidates.
3. A low-cost cloud model handles uncertain or multi-message cases with explicit opt-in.
4. A tool-running model is reserved for customer-requested, bounded work.

Process deltas, cache by content hash, batch non-urgent events, keep rolling summaries, enforce daily budgets, and fall back to rules-only without stopping sync. Use webhooks/change notifications rather than five-minute polling.

## Privacy modes

### Private/local

Credentials remain in Keychain, content is processed on-device, and only derived Moves or explicitly selected artifacts sync. Offline devices reconcile later.

### Always-on

A separate paid opt-in may store encrypted connector credentials on the backend and process while devices are offline. It requires formal retention, deletion, security, incident-response, audit, and vendor-review controls before launch.

## Implementation sequence

1. Stabilize the notch, repository, recovery, onboarding, and signed calendar identity.
2. Add explicit dependency details to Blocked.
3. Build `SourceEvent → Signal → SuggestedAction → Approval → Execution` with an immutable user-owned activity ledger.
4. Build Connections and Privacy with per-account health, pause, disconnect, and erase.
5. Ship Calendar plus manual Share/Paste capture.
6. Pilot one official Gmail-to-authorized-Drive-to-Needs-You workflow.
7. Measure precision, dismissals, accepted suggestions, time saved, and cost per accepted action.
8. Add other official connectors only after the first workflow is reliable.

Agent execution ships through a separate sequence: provider-neutral review UI, a scoped Developer ID helper, Codex app-server, Claude cloud sessions, and then Claude local execution. Local provider processes remain outside the App Store target.

No communications connector or automatic sending is enabled by this document.
