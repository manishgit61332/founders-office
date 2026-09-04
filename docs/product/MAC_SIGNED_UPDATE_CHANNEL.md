# Signed Mac update channel

The update feed is a signed pointer to an already sealed direct-download release. It is not an installer.

## One-time key setup

Use an offline release Mac with FileVault and a restricted operator account. Create the private Ed25519 key directly in a non-synchronizing Keychain item and write only the public key to a new file:

```bash
swift run FounderOfficeUpdateSigner \
  --generate-key \
  --keychain-service com.foundersoffice.release.update-signing \
  --keychain-account production \
  --public-key-output /secure/release/update-public-key.txt
```

The command refuses to replace an existing Keychain item or output. Back up the release Keychain through the organization’s reviewed secret-recovery process. Do not export the private key into the repository, CI variables, shell history, release metadata, or the application bundle.

The base64 public key and exact feed URL are required public release settings:

```bash
export FOUNDER_OFFICE_UPDATE_FEED_URL="https://DOWNLOAD_ORIGIN/channel/macos-beta-v1.json"
export FOUNDER_OFFICE_UPDATE_CHANNEL="beta"
export FOUNDER_OFFICE_UPDATE_PUBLIC_KEY="PUBLIC_KEY_FROM_REVIEWED_FILE"
```

`Scripts/release-macos.sh` embeds and verifies them. `Scripts/verify-macos-release.sh` requires the same values as independent operator inputs when checking downloaded bytes.

## Sign a rollout

First run the complete Mac release pipeline, upload the immutable ZIP and `release.json`, download them again, and pass the independent verifier. Then sign a feed envelope from those verified local bytes:

```bash
swift run FounderOfficeUpdateSigner \
  --keychain-service com.foundersoffice.release.update-signing \
  --keychain-account production \
  --metadata /verified/release.json \
  --verified-artifact /verified/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --artifact-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --evidence-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/release.json \
  --feed-url "$FOUNDER_OFFICE_UPDATE_FEED_URL" \
  --channel beta \
  --expected-public-key "$FOUNDER_OFFICE_UPDATE_PUBLIC_KEY" \
  --sequence MONOTONIC_FEED_SEQUENCE \
  --rollout-id NEW_RANDOM_UUID \
  --starts-at 2026-09-01T09:00:00Z \
  --phase-count 10 \
  --phase-interval-seconds 86400 \
  --output /publish/macos-beta-v1.json
```

For an isolated signing service, replace the two Keychain options with `--stdin-key` and pipe the 32-byte private key (raw or canonical base64) directly into standard input. Never use command substitution, an argument, or an environment variable for the private key. `--expected-public-key` is public release configuration and prevents signing with the wrong offline Keychain item.

Increase `--sequence` for every changed envelope, including pause or rollback records. The app remembers the highest accepted sequence and payload digest within a content-free namespace derived from the reviewed feed URL, channel, and public key. It rejects an older sequence or a different payload that reuses a sequence, while a reviewed channel move or key rotation starts an isolated history. The signer also refuses linked, missing, oversized, mismatched, or unsealed inputs; mutable artifact paths; a different origin; unsafe rollout bounds; and replacement of an existing output. Publication storage must still provide object versioning and restricted writes.

## Pause, critical release, and rollback evidence

Publish a newly signed envelope with the same reviewed release and `--paused` to stop all offers. Do not edit an existing signed envelope in place.

`--critical` makes an eligible corrective build available to every installation immediately, while a paused feed still wins. A rollback record describes the incident that a higher corrective build resolves:

```text
--rollback-build AFFECTED_OLDER_BUILD
--rollback-reason stability
--incident-id INCIDENT_UUID
```

Allowed reasons are `data_integrity`, `privacy`, `security`, and `stability`. Founder’s Office never installs an older build. Every correction receives a higher Apple build number and a new sealed artifact.

## Runtime behavior

- Automatic checks start after onboarding and runtime readiness, at most once per day.
- Manual checks are available from the status-item menu.
- No redirect, non-JSON response, oversized response, invalid signature, cross-origin URL, or malformed rollout can open a download.
- The customer chooses **Open Download**. macOS opens the exact signed immutable URL in the default browser.
- Founder’s Office does not install, execute, delete, or replace application code.

Signing, notarization, clean-Mac installation, public-origin verification, staged rollout, withdrawal, and corrective-build evidence remain required release gates. This repository does not contain the credentials needed to claim those gates have passed.
