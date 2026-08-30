# Reliability and safe auto-remediation

The product reports failures without collecting the founder's work. It repairs only states that are derived, bounded, and reversible.

## Health signals

Use Apple Unified Logging and signposts for macOS launch, latency, CPU, memory, disk, and energy investigation. Use the MetricKit diagnostic payloads that macOS supports for real-device crash and hang evidence; do not call the iOS-only metric-payload or extended-launch APIs from the Mac target. Keep diagnostics local by default.

The app records a small local health envelope:

```text
timestamp, build, schema, subsystem, operation, outcome,
durationBucket, errorDomain, errorCode, recoveryAttempt, correlationID
```

It must not contain task titles, calendar labels, people, photos, prompts, model output, paths, filenames, credentials, or provider account names.

## Customer-visible reporting

The app needs one Health surface with:

- current status for local data, sync, calendar, startup, and assistant execution;
- the last successful operation time;
- a plain-language action when the customer must intervene;
- “Export redacted support bundle” with a preview of every included field;
- “Copy incident ID” for support.

Lag is a defect when any of these release budgets fail:

- notch interaction misses the 60 Hz frame budget on supported hardware;
- pointer-to-open feedback exceeds 100 ms at the 95th percentile;
- a local task mutation takes more than 250 ms at the 95th percentile;
- launch-to-ready exceeds 1.5 seconds at the 95th percentile;
- background work causes sustained high-energy diagnostics.

## Automatic repair boundary

| Automatic | Ask first | Never self-repair in production |
|---|---|---|
| Retry bounded network failures with jitter | Restore a quarantined canonical file | Rewrite corrupt canonical data |
| Reattach file and calendar observers | Switch or merge cloud accounts | Change credentials or permissions |
| Rebuild generated Markdown and widget projections | Reset a connector cursor | Complete, delete, send, publish, or spend |
| Recreate disposable image caches | Enter safe mode after a crash loop | Download code and patch the installed app |
| Pause a failing optional connector | Erase local or cloud data | Run an AI-generated migration without review |

Every repair has a maximum attempt count, a timeout, an idempotency key, a before/after health check, and a durable outcome. Three failed attempts stop the repair and create a Needs You item.

## Crash-loop safe mode

If the app fails before ready three times for the same build, the next launch enters safe mode. Safe mode keeps canonical local data read-only and disables Cloud sends, assistant execution, connectors, large-image decoding, and nonessential animation. It offers export, diagnostics, and an explicit retry.

## AI-assisted fixes

Codex or Claude may investigate a reproducible issue in an isolated branch. The agent receives a redacted fixture, failing test, and narrow repository scope. It may open a pull request only after tests and static checks pass. A human reviews and ships the signed update. The installed app never edits its own executable or source.

## Release evidence

Each release records crash-free sessions, hang rate, launch percentiles, interaction signposts, memory peak, energy regressions, open P0 defects, migrations, rollback steps, and the exact signed artifact hash.

- [MetricKit](https://developer.apple.com/documentation/metrickit)
- [Logging and evidence policy](../LOGGING.md)
