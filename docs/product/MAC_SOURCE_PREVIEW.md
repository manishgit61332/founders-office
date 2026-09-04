# Mac source preview

This is the fastest safe path for a small group of technical testers before an
Apple Developer ID certificate is available. Each tester clones a reviewed
commit and builds the app locally. No unsigned or ad-hoc `.app` bundle is sent
between Macs.

## What it is

- A source-built **Development** channel.
- Ad-hoc signed on the tester's own Mac.
- Local-only unless a separate development service is deliberately configured.
- Bound to the checkout that built it.
- Updated manually after the tester reviews and fast-forwards the checkout.

It is not a notarized Beta, cannot open the website download gate, and is not
suitable for nontechnical testers.

## Tester requirements

- macOS 14 or later.
- About 15 minutes for the first dependency download and build.
- Apple Command Line Tools. Install them from Apple's normal system prompt by
  running `xcode-select --install`; the project never automates that install.
- Git and an internet connection for the first build.
- The exact approved branch, tag, or commit from the release coordinator.

No Apple Developer membership, signing certificate, Supabase token, OAuth
secret, or access to another person's workspace is required.

## Clean install

Use only the exact approved ref. Until the preview branch is merged, the current
review ref is `codex/mac-source-preview`:

```bash
git clone --branch codex/mac-source-preview --single-branch \
  https://github.com/manishgit61332/founders-office.git
cd founders-office
git checkout FULL_COMMIT_SHA
Scripts/install-source-preview.sh --expected-commit FULL_COMMIT_SHA
```

The installer prints the full commit SHA and installed app path. On first
launch, choose a new local workspace; never copy another tester's runtime files.
Calendar access and launch at login remain explicit macOS choices.

## Update

First inspect the incoming commits. Then:

```bash
git status --short
git pull --ff-only
git checkout FULL_COMMIT_SHA
Scripts/install-source-preview.sh --expected-commit FULL_COMMIT_SHA
```

The app asks the running copy to quit safely before replacing it. If an edit or
popup is unfinished, finish or discard that action and run the installer again.
The ignored SQLite workspace remains in the checkout across a normal fast-forward
and reinstall.

## Removal and data

Export any work that matters before removing the source checkout. The preview's
canonical SQLite workspace and image assets are private ignored files stored
beside the checkout. They are not backed up or cloud-synced by this workflow.

Move `Founder's Office.app` from the current user's Applications folder to the
Trash and remove the checkout only after the export is verified. Do not publish
the checkout with runtime files force-added to Git.

## Distribution boundary

Never send `dist/development/Founder's Office.app` or an archive of it to a
friend. An ad-hoc signature does not establish the publisher identity and Apple
has not notarized the bytes. There is deliberately no instruction to remove the
quarantine attribute, override Gatekeeper, or enable the website download.

The normal invited-tester path remains the immutable Developer ID-signed,
notarized, stapled, independently verified Beta described in
`MAC_DIRECT_DISTRIBUTION.md`.
