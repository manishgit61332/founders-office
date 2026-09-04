# Release records

Create one immutable record for every distributed build. Include:

- semantic version and Apple build number;
- date, tag, and commit;
- schema and migration versions;
- user-visible changes;
- permission and privacy changes;
- test, signing, notarization, CloudKit, and device evidence;
- known issues and rollback steps;
- artifact checksums or App Store build identifiers.

`CHANGELOG.md` is customer-facing; release records are operational evidence.

## macOS direct downloads

Use [the macOS direct-distribution runbook](../product/MAC_DIRECT_DISTRIBUTION.md). `Scripts/release-macos.sh` requires the record before it archives the app and copies the record into a sealed release directory.

Each published macOS artifact must ship with:

- the notarized ZIP;
- its `.sha256` file;
- strict-schema `release.json` with the tag, commit, version, build, identifiers, CloudKit enablement, minimum system version, architectures, signing result, notarization submission ID, Gatekeeper result, and artifact hash;
- the release record;
- signing, entitlement, notarization, and Gatekeeper evidence.
- write-once `clean-mac-acceptance.json`, bound to the exact manifest, artifact, immutable URLs, clean test environment, restart, upgrade, export, erase, recovery, and staged-update results.

Release URLs are immutable. Withdraw a bad build and publish a higher build number. Never replace bytes under an existing release URL.
