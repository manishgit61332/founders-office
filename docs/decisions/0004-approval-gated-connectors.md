# ADR 0004: Event-driven, approval-gated connectors

- Status: Accepted
- Date: 2026-08-30

## Context

The product may eventually recognize commitments in explicitly connected calendars, email, documents, and supported business messaging. Polling another application's private database is unreliable and incompatible with a trustworthy product.

## Decision

Use official provider APIs, OS frameworks, webhooks/change cursors, least-privilege scopes, deterministic filtering, and on-device reasoning first. Personal WhatsApp uses explicit Share/Forward/Paste; it is not passively scraped. External sends, shares, mutations, purchases, and deletions remain approval-gated.

## Consequences

Basic sync consumes no model credits. Some provider integrations require OAuth review, security assessment, and an always-on relay. V1 stops at suggest, draft, copy, or open in source.

## Privacy and security

Inbound content is untrusted data. The policy engine—not the model—controls available tools.

## Migration and rollback

No connector is enabled by this ADR. Each future connector ships behind a permission and capability flag with independent disconnect and erase controls.
