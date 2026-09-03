# macOS direct-distribution runbook

The public download stays closed until this runbook passes. A local ad-hoc app is not a release candidate.

## Release contract

A website build is publishable only when all of these statements are true:

1. The source comes from a clean commit with an exact `vX.Y.Z` tag.
2. The product version and Apple build number have a matching release record.
3. Apple product identifiers belong to the production organization and will not change after launch.
4. Xcode signs the app with a `Developer ID Application` certificate and the production provisioning profile.
5. Every required architecture has the expected signature, hardened runtime, and trusted timestamp.
6. Every required architecture's effective entitlements enable App Sandbox, outbound HTTPS, Sign in with Apple, Calendar access, and user-selected read-only file access, with no CloudKit or APNs capability.
7. The app's runtime configuration names the reviewed public Supabase endpoint and key and contains no retired CloudKit writer configuration.
8. Apple accepts the notarization submission.
9. The notarization ticket is stapled to the app.
10. Gatekeeper reports `Notarized Developer ID` for the stapled app.
11. The customer executable has no external Codex runner, workspace override, or preview/capture hook.
12. The privacy manifest exactly matches the committed, reviewed privacy policy.
13. The final ZIP matches the SHA-256 and sealed `release.json` record.
14. The app embeds the independently reviewed HTTPS update-feed URL and Ed25519 public key, and its sandbox includes outbound network access without temporary exceptions.

`Scripts/release-macos.sh` enforces this contract. It stops at the first failed condition and does not leave a publishable directory.

## One-time Apple setup

Complete these steps before the first external beta:

1. Install full Xcode and select it with `xcode-select`. Command Line Tools alone are insufficient.
2. Install XcodeGen 2.46.0, the same version pinned in CI. The release script rejects another version and generates the Xcode project from the committed `project.yml`.
3. Freeze the organization Team ID, macOS bundle ID, App Group, and product-auth callback scheme. The release script explicitly rejects the known provisional bundle identifier in the repository.
4. Create a `Developer ID Application` certificate for that team and install its private key in the release keychain.
5. Create a Developer ID provisioning profile for the final macOS bundle ID. It must authorize Sign in with Apple without granting the retired CloudKit or push capabilities.
6. Create and commit `Config/Release/FoundersOfficeMac.entitlements` after the identifiers are frozen. The release script accepts no external or untracked entitlement file. It must contain:
   - `com.apple.security.app-sandbox` set to `true`;
   - `com.apple.developer.applesignin` set to an array containing only `Default`;
   - `com.apple.security.personal-information.calendars` set to `true`;
   - `com.apple.security.files.user-selected.read-only` set to `true` so a customer can explicitly choose a vision image without broad file access.
   - `com.apple.security.network.client` set to `true` for the signed update feed and production sync transport.

   CloudKit, APNs, debug, JIT, unsigned-memory, library-validation bypass, and temporary-exception entitlements are release blockers.
7. Store notarization credentials in Keychain. Do not put an Apple password, private key, issuer ID, or notary token in the repository.

For an interactive local release, create the Keychain profile once:

```bash
xcrun notarytool store-credentials founders-office-notary \
  --apple-id RELEASE_APPLE_ID \
  --team-id TEAM_ID
```

The command asks for the app-specific password without writing it to the shell script. A release service should use a locked CI keychain and encrypted CI secrets instead.

Apple's current process is documented in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## Prepare a release

1. Pass the repository checks and the paid-beta gates.
2. Update the version and build record at `docs/releases/vX.Y.Z-build-N.md`.
3. Commit every intended change. Leave no untracked file in the worktree.
4. Create the exact `vX.Y.Z` tag on that commit.
5. Set the non-secret release selectors for the current shell:

```bash
export FOUNDER_OFFICE_TEAM_ID="TEAM_ID"
export FOUNDER_OFFICE_BUNDLE_ID="FINAL_ORGANIZATION_BUNDLE_ID"
export FOUNDER_OFFICE_DEVELOPER_ID_APPLICATION="Developer ID Application: ORGANIZATION (TEAM_ID)"
export FOUNDER_OFFICE_PROVISIONING_PROFILE_SPECIFIER="PRODUCTION_PROFILE_NAME"
export FOUNDER_OFFICE_NOTARY_PROFILE="founders-office-notary"
export FOUNDER_OFFICE_UPDATE_FEED_URL="https://DOWNLOAD_ORIGIN/channel/macos-beta-v1.json"
export FOUNDER_OFFICE_UPDATE_CHANNEL="beta"
export FOUNDER_OFFICE_UPDATE_PUBLIC_KEY="REVIEWED_ED25519_PUBLIC_KEY"
```

Do not copy the example values. The script validates the installed certificate, provisioning choice, bundle, signature, and effective entitlements.

The default product is universal for Apple silicon and Intel. If the product decision explicitly drops Intel support, record that decision and set `FOUNDER_OFFICE_REQUIRED_ARCHS=arm64` for the release. Do not change architecture support silently.

## Build, sign, notarize, and seal

Run:

```bash
Scripts/release-macos.sh --version X.Y.Z --build N
```

The script performs an Xcode archive and Developer ID export, then:

- accepts only a three-component numeric product version such as `1.2.3`;
- checks the bundle identifier, version, build, Supabase-only sync authority, architectures, app icon, and the exact reviewed privacy-manifest semantics;
- rejects a developer workspace path in the app;
- rejects customer binaries containing external Codex execution, workspace override, or preview/capture hooks;
- verifies the timestamped Developer ID signature and hardened runtime for every required architecture;
- verifies the tracked source entitlements and each architecture's effective production entitlements, including Sign in with Apple, Calendar, user-selected read-only file access, and outbound HTTPS;
- rejects CloudKit and APNs entitlement or runtime configuration from the customer app so a legacy migration source cannot become a competing writer;
- submits a ZIP to Apple and requires an `Accepted` result;
- staples and validates the ticket;
- requires a passing Gatekeeper assessment;
- creates the final ZIP and SHA-256;
- creates strict-schema `release.json` metadata and copies the release record and verification evidence;
- embeds and verifies the exact signed-update feed URL and Ed25519 public key;
- runs an independent extraction-and-verification pass;
- writes a new read-only directory under `dist/releases/macos/`.

The script refuses to reuse a version, build, tag, and commit path and makes the local output read-only. Local file permissions are not immutable storage: the publication origin must enforce object versioning or retention. Publish a new build to correct a defect; never replace an existing ZIP at the same URL.

## Stage the immutable release

Upload only the final ZIP from the sealed release directory. Upload `release.json`, `release-record.md`, and the `.sha256` file beside it. Use a versioned, immutable object URL. Configure the download response as an attachment and do not serve user-uploaded content from the release origin. Do not enable the website download yet.

Keep the website download control disabled until the artifact exists at the immutable URL and a clean Mac passes the verification below. The website requires both a committed verified-release manifest and an independently configured HTTPS origin before it renders the download. Never point the website at:

- `dist/development/`;
- an Xcode archive export that has not completed this script;
- a mutable `latest.zip` object;
- a file with no matching `release.json` and SHA-256.

After upload, download the public bytes again. Verify those bytes, not the local pre-upload copy:

```bash
Scripts/verify-macos-release.sh \
  --artifact /path/to/downloaded/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --metadata /path/to/downloaded/release.json \
  --expected-team-id TEAM_ID \
  --expected-bundle-id FINAL_ORGANIZATION_BUNDLE_ID \
  --expected-update-feed-url https://DOWNLOAD_ORIGIN/channel/macos-beta-v1.json \
  --expected-update-channel beta \
  --expected-update-public-key REVIEWED_ED25519_PUBLIC_KEY \
  --expected-archs "arm64 x86_64"
```

That verification does not enable the website. Complete the clean-Mac gate below first.

After the clean-Mac record is uploaded at its exact immutable path, generate the website gate from the same canonical metadata, verified downloaded ZIP, and acceptance bytes. The artifact, manifest, and acceptance URLs must use the same immutable version/build/commit path and one canonical lowercase HTTPS origin without an explicit default port. `latest` aliases, redirects, query aliases, and parser-normalized URL aliases are rejected:

```bash
python3 Scripts/prepare-website-mac-release.py \
  --metadata /path/to/downloaded/release.json \
  --verified-artifact /path/to/downloaded/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --clean-mac-acceptance /path/to/downloaded/clean-mac-acceptance.json \
  --download-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --approved-origin https://DOWNLOAD_ORIGIN \
  --output Website/release/mac-release.json
```

Set `FOUNDER_OFFICE_APPROVED_DOWNLOAD_ORIGIN` to that same bare HTTPS origin in the website deployment. CI exercises deny fixtures so a malformed or manually loosened manifest stays closed.

After the public artifact and evidence pass this verification, create the signed staged feed with `FounderOfficeUpdateSigner` and the process in [Signed Mac update channel](MAC_SIGNED_UPDATE_CHANNEL.md). Publishing an unsigned, hand-edited, redirected, or cross-origin feed does not open a download in the app.

Publish the final Team ID, bundle ID, Supabase sync authority, and supported architectures on the release page. Pass the identity values to the verifier independently; do not trust values read only from the downloaded metadata.

## Clean-Mac acceptance

Use a macOS account that has never installed Founder's Office. It must not have the developer certificate or source checkout.

1. Download the staged ZIP, `release.json`, and `release-record.md` directly from their immutable release-origin paths into the same directory. The website button remains disabled.
2. Run the independent release verifier.
3. Drag the app to Applications and launch it through Finder.
4. Confirm there is no Gatekeeper bypass instruction.
5. Complete onboarding in local-only mode first.
6. Grant Calendar access, relaunch, and confirm the permission and selected calendars persist.
7. Restart the Mac and verify the launch-at-login choice.
8. Install the next signed build and verify preferences and user data survive the upgrade.
9. Verify workspace export, erasure, recovery, and relaunch from each supported outcome.
10. Verify a staged signed feed offers the exact immutable URL, a paused feed offers nothing, and a higher corrective build carries rollback evidence without attempting a downgrade.

Record the evidence only after every check passes. `--passed` must be repeated for all values shown by `--help`; omitting any one check refuses the record:

```bash
python3 Scripts/record-macos-clean-acceptance.py \
  --metadata /path/to/downloaded/release.json \
  --verified-artifact /path/to/downloaded/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --approved-origin https://DOWNLOAD_ORIGIN \
  --artifact-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/FoundersOffice-X.Y.Z-build-N-macOS.zip \
  --canonical-manifest-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/release.json \
  --acceptance-record-url https://DOWNLOAD_ORIGIN/releases/macos/vX.Y.Z/build-N/FULL_COMMIT/clean-mac-acceptance.json \
  --mac-model MAC_MODEL_IDENTIFIER \
  --macos-version X.Y.Z \
  --confirm-clean-account \
  --confirm-no-developer-certificate \
  --confirm-no-source-checkout \
  --passed immutablePublicOriginDownload \
  --passed independentReleaseVerification \
  --passed cleanInstall \
  --passed gatekeeperLaunch \
  --passed onboarding \
  --passed calendarPermissionRetention \
  --passed launchAtLoginRestart \
  --passed signedUpgradeDataRetention \
  --passed workspaceExport \
  --passed workspaceErase \
  --passed recovery \
  --passed stagedUpdate \
  --passed pausedUpdate \
  --passed correctiveRollbackEvidence \
  --output /path/to/clean-mac-acceptance.json
```

Upload this file once at the declared acceptance-record URL, download it again, and use those downloaded bytes when preparing the website gate. A test on the development Mac is not sufficient evidence. Passing confirmations without performing the tests is a release-process violation, not acceptance. The file is labeled as operator-confirmed evidence; it is not a cryptographic attestation. The command refuses to overwrite an existing acceptance file, so a correction requires a new release evidence path rather than replacing prior evidence.

## Failure and rollback

Notarization rejection, a Gatekeeper failure, an entitlement mismatch, or a checksum mismatch blocks publication. A rejected or interrupted notarization response is preserved under `dist/release-failures/macos/`, outside the publishable release path. Retrieve Apple's notarization log with its submission ID, fix the source or release configuration, increase the build number, and run the full process again.

If a published build is unsafe, remove its download link and mark it withdrawn. Keep its immutable artifact and evidence for incident review. Publish a higher build number after the fix; do not replace the withdrawn bytes.

## Local development remains separate

`Scripts/build-app.sh` still supports fast local installation. It writes to `dist/development/`, uses an ad-hoc signature, embeds the checkout path, disables release claims, and prints a non-distributable warning. This is intentional. It cannot be promoted into a website download.
