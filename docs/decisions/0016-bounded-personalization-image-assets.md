# ADR 0016 — Bounded personalization image assets

- Status: Accepted
- Date: 2026-08-31

## Context

The first Mac implementation copied a selected image into the personalization directory and loaded that same file with `NSImage`. A high-resolution or maliciously dimensioned source could therefore create unnecessary decode and memory pressure. The same filename was also the only prospective sync asset, so there was no enforceable boundary between exact original bytes, the notch-sized display, and a cross-device transfer.

Images are customer-private data. A repository failure must not leave canonical state pointing at a partial file set, removal must not delete files before the canonical commit, and cleanup must never accept a synced filename as an arbitrary filesystem path.

## Decision

1. Personalization schema version 6 gains an optional `visionImageAsset` metadata value with its own version-1 schema. The existing `photoFileName` remains a compatibility pointer to the bounded display JPEG. Documents without the optional value continue to decode unchanged.
2. The asset ID is an opaque UUID. Original, display, and sync filenames are derived from that ID and a fixed role; remote or edited data cannot supply paths. Legacy cleanup accepts only the previous exact `vision-<uuid>.<image-extension>` form.
3. Import first copies the chosen source as a file into a private staging directory. It never reads the original into `Data` or constructs an `NSImage` from it. ImageIO opens with caching disabled, reads first-frame metadata, and creates transformed thumbnails with `CGImageSourceCreateThumbnailAtIndex`.
4. Source files are limited to 96 MiB, 32,768 pixels on either axis, 120 million pixels, and 256 frames. The display JPEG is capped at 1,600 pixels and 8 MiB; the sync JPEG is capped at 960 pixels and 3 MiB. Even injected configurations cannot exceed reviewed 12 MiB and 5 MiB output ceilings.
5. The exact original is retained locally with private file permissions. The notch and settings preview resolve only the display variant. The manifest exposes a separate sync filename that every future authenticated asset transport must use. Original bytes are read only after the customer presses **Export original…** and chooses a destination.
6. Staged files receive unique final names and are atomically renamed before the SQLite callback. If the repository callback fails, the actor immediately removes every new final file; launch reconciliation retries any deletion the operating system temporarily prevents. Only after a canonical commit succeeds are all prior owned variants retired.
7. Launch reconciliation removes stale staging directories and strict unreferenced owned variants. It preserves legacy arbitrary basenames, the current manifest, and all siblings of a bounded display compatibility pointer. Cleanup failures are retried on a later launch; they never reverse a successful canonical commit.
8. Image preparation, thumbnailing, copies, exports, and cleanup run inside an actor outside `MainActor`. The final personalization candidate is built from the latest MainActor document immediately before commit, so concurrent name, Appearance, milestone, or goal edits are not replaced by a stale snapshot. A concurrent change to the image field itself fails the operation and rolls the prepared files back.
9. Diagnostics record only finite import, export, and cleanup operation identifiers with outcome or error domain/code. They never record filenames, paths, image metadata, or customer content.

## Consequences

- A very large source has bounded variant dimensions and an explicit source safety ceiling. ImageIO may still require format-dependent internal work, so physical-device memory profiling remains a release gate rather than an assumption derived from unit tests.
- The sync variant is generated and represented now; uploading it remains the responsibility of the authenticated asset sync transport. The local Mac release does not claim cross-device photo sync before that transport passes its gate.
- Exact originals are intentionally not part of workspace JSON/Markdown export. They leave app storage only through the explicit original-export action.
- An older client can display the compatibility JPEG. If it drops the optional manifest, launch reconciliation preserves the sibling original and sync files, but the current UI cannot offer exact-original export until the manifest is restored through a reviewed recovery flow.

## Privacy and security

- Originals, variants, staging files, and exports are private runtime data excluded from source control.
- Derived basenames, standardized parent checks, symlink rejection, file permissions, and strict role parsing prevent traversal and broad cleanup.
- Output JPEGs omit source metadata, reducing the information transferred to a future sync service.
- No automatic repair modifies canonical image metadata or invents a missing original.

## Migration and rollback

No eager data migration is required. Existing `photoFileName` images remain readable. The next customer-selected image creates the optional v1 manifest and bounded variants. Removing the new code leaves the bounded display JPEG available through the compatibility field; it must not delete retained originals during rollback.

## Related work

- ADR 0006 — Composable, versioned appearance personalization
- ADR 0010 — Serialized transactional workspace repository
- ADR 0013 — Adopt SQLite as the Mac workspace authority
- `Sources/FounderOfficeCore/PersonalizationImageStore.swift`
- `Tests/FounderOfficeCoreTests/PersonalizationImageStoreTests.swift`
- `Tests/OpenLoopsStorageTests/WorkspaceSessionIntegrationTests.swift`
