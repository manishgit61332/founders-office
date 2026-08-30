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
