# ADR 0019: Clean-Mac acceptance gates the public download

## Status

Accepted

## Context

Developer ID signing, notarization, stapling, Gatekeeper assessment, and an
artifact checksum prove release provenance. They do not prove that onboarding,
Calendar permission retention, launch at login after restart, signed upgrades,
workspace export and erasure, recovery, or staged updates work on a customer
Mac. The website gate previously accepted the sealed release manifest and ZIP
without machine acceptance evidence, so an operator could expose a download
before completing the documented clean-Mac gate.

## Decision

The canonical `release.json` remains the immutable signing and notarization
record. A second write-once `clean-mac-acceptance.json` is created only after
one exact artifact passes every clean-Mac check. Its strict schema binds the
canonical manifest SHA-256, artifact SHA-256 and size, version, build, commit,
and the exact immutable HTTPS paths for the artifact, canonical manifest, and
acceptance record.

The clean-Mac record is explicitly labeled `operator-confirmed`. It is an
accountable release-process record, not a cryptographic attestation. Repository
review, immutable origin retention, and the independently configured website
origin remain part of the trust boundary.

The record contains explicit `passed` outcomes for clean installation,
Gatekeeper launch, onboarding, Calendar retention, launch at login after a
restart, signed-upgrade data retention, export, erasure, recovery, staged and
paused updates, and corrective-build rollback evidence. It also records the
Mac model and macOS version, plus explicit confirmation that the account had no
prior Founder’s Office state, Developer ID certificate, or source checkout.

`Scripts/prepare-website-mac-release.py` requires both records and the verified
ZIP. It independently validates their exact schemas and bindings. Its website
manifest is schema 2 and includes the acceptance-record SHA-256 and immutable
URL, plus the canonical-manifest URL. The website parser rejects schema 1,
absent or failed acceptance, mutable paths, cross-origin paths, hostname case
aliases, explicit default ports, unknown fields, and mismatched release
identity. Evidence inputs are pinned as regular non-symlink files while they
are read, and the acceptance record is published with an atomic no-overwrite
operation.

The acceptance command is an operational attestation, not a way to simulate
physical evidence. Passing command-line confirmations without performing the
checks violates the release process. No repository or development-Mac test can
make the clean-Mac gate pass.

## Consequences

The website stays fail closed after notarization until a separate clean Mac
passes the full checklist. A first public release therefore needs an internal,
signed predecessor to exercise upgrade retention. The acceptance JSON must be
published beside the immutable release files before the website manifest is
enabled.

## Rollback

Reverting the website to schema 1 would reopen the original release loophole
and is not a safe rollback. If the acceptance tooling fails, keep the download
disabled, fix the tooling on a higher commit, repeat the clean-Mac run, and
create a new write-once acceptance record.
