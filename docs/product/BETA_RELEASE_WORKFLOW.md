# One-build beta workflow

Founder’s Office has one visible app per audience. Old artifacts remain immutable release evidence, not alternative downloads.

## Channels

| Channel | Audience | Installation | Updates |
| --- | --- | --- | --- |
| Development | Manish and developers | `Scripts/build-app.sh --install` | Replaced locally after checks pass |
| Beta | Invited testers | Latest Developer ID-signed and notarized ZIP from the website | Signed `beta` feed, manual **Check for Updates**, and automatic checks after launch readiness |
| Stable | Public customers | Latest signed and notarized website download | Separate signed `stable` feed |

The Development bundle must never be shared. It is ad-hoc signed, embeds the local repository path, and may include development-only capabilities. Beta and Stable are customer Release builds.

## Version rule

- The customer-visible version uses `major.minor.patch`.
- The Apple build number always increases.
- Every tester-visible change receives a new immutable version and build. Example: `0.11.0 (14)` followed by `0.11.1 (15)`.
- Never replace bytes belonging to an existing version, build, tag, checksum, or URL.
- `Apps/macOS/Info.plist` and `Resources/Info.plist` must match. `Scripts/verify-app-version.py` and CI reject drift.

## Change flow

1. Create a short `codex/...` branch for one coherent change.
2. Add the customer-visible outcome to `CHANGELOG.md`.
3. Run repository safety, Swift/website tests, UI automation, and visual acceptance.
4. Merge the reviewed commit into `main`.
5. Increase the version/build and create the matching signed Git tag.
6. Produce one Developer ID-signed, notarized, stapled artifact from that clean tag.
7. Verify the downloaded bytes on a clean Mac and record the acceptance evidence.
8. Publish the immutable artifact and sign a higher-sequence `beta` feed envelope.
9. Update the website’s release manifest to point to that exact accepted artifact.

At that point every invited tester sees the same Beta. A manual update check exposes the new build immediately; automatic checks remain bounded so the app does not poll aggressively. Founder’s Office never silently replaces a running app or installs unsigned code.

## Tester feedback loop

Every report must include the version and build shown in Founder’s Office:

1. Tester reports a bug or request using the beta support route.
2. Triage records expected behavior, actual behavior, reproduction steps, surface, severity, and redacted evidence.
3. The fix is linked to a GitHub issue and pull request.
4. CI and acceptance evidence must pass before a new Beta is published.
5. Release notes state which tester reports are fixed.

Never collect real Moves, calendar content, names, photos, credentials, or communications in a GitHub issue. Use synthetic reproduction data and the app’s redacted Health report.

## Website

The website may be deployed continuously, but the Mac download stays fail-closed. A website deployment does not make an app build distributable. `Website/release/mac-release.json` becomes available only after the signed artifact and clean-Mac acceptance record match.
