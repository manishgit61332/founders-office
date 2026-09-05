# Founder's Office for Windows — DEVELOPMENT build

This bundle is for testing on Windows 11 build 22621 or later. It is not a
production beta and is not signed with the future production identity.

The package includes its .NET runtime. The bundle contains only x64 or neutral Windows App Runtime dependencies.
The installer supports the default Windows PowerShell 5.1. No separate .NET installation or developer tools are required.
The actual MSIX version must match `BUILD-INFO.txt` before this bundle can pass verification.

The MSIX is signed in GitHub Actions with a short-lived, self-signed development
certificate whose public half is included in this bundle. The private key is
destroyed with the build runner and is never included here.

## Install

1. Extract the complete ZIP. Do not run the installer from inside the ZIP.
2. Check that this is the exact development bundle supplied for your test. Trusting its self-signed certificate is an explicit development-only security decision.
3. Double-click `FounderOfficeDevelopment.cer`, select **Install Certificate**, then **Local Machine**. Approve the administrator prompt only if you intend to trust this development signer. Select **Place all certificates in the following store**, then **Trusted People**. Do not select Trusted Root Certification Authorities. Ask your device administrator for help if you cannot approve this step.
4. As your normal Windows user, right-click `Install-Development.ps1` and choose **Run with PowerShell**.
5. Open **Founder's Office** from Start.

If PowerShell blocks the downloaded script, open Properties for the ZIP, select
**Unblock**, extract it again, and rerun the installer. Organization-managed
Windows devices may disallow test certificates or sideloaded apps.

The installer verifies the included file hashes and confirms that the MSIX was
signed by the bundled certificate. It then checks that the exact certificate is already trusted in Local Computer → Trusted People.
It does not change certificate trust or request elevation. Certificate trust requires administrator approval separately, once for each new development signer.
The application is installed for the Windows user who runs the installer, not for a different administrator account.
Microsoft documents this [development certificate trust requirement](https://learn.microsoft.com/en-us/windows/msix/msix-troubleshooting-guide).

## What to test

- Add a Move with a title, description, priority, and optional deadline.
- Edit those fields, then close and reopen the app to confirm persistence.
- Complete a Move, find it in Completed history, and reopen it.
- Hide and reopen the surface from the notification-area icon.
- Right-click the icon and test **Open/Hide** and **Exit**.

## One-time laptop check

Use this exact bundle on each Windows 11 x64 laptop. The certificate setup above needs administrator approval; no developer tools, cloud VM, or Google login are needed.
Use synthetic Moves only. Keep `BUILD-INFO.txt` and `SHA256SUMS.txt` with the extracted bundle.

1. Install and open the app using the instructions above.
2. Create a synthetic Move, then hide the app through its tray icon.
3. Open it from Start three times. Expect one app window and one tray icon.
4. Press **Win+R** and open this synthetic link:

   ```text
   founders-office-dev://auth/callback?code=synthetic-not-a-real-code
   ```

5. Expect **Sign-in link not used**. Product sign-in remains unavailable, and the existing Move remains intact.
6. Repeat the link. Expect no account change, duplicate Move, window, or tray icon.
7. Repeat with `/Callback` instead of `/callback`. Expect rejection without account or Calendar changes.
8. Choose **Exit** from the tray. Open the original synthetic link again and verify the same unchanged workspace.
9. Confirm the three separate states: **Product account**, **Move sync**, and **Windows Calendar**.

Windows may ask which app should open its development protocol. Choose this development app if prompted.
If installation, activation, or persistence fails, stop and report the step number plus the commit from `BUILD-INFO.txt`.
Do not send callback URLs from real sign-in, tokens, personal Move details, or unredacted screenshots.

## Separate connection states

- **Product account:** Native sign-in controls exist, but this build's registration-approval gate remains closed. It cannot perform Google login.
- **Move sync:** Changes stay in this Windows user's private local app data.
- **Windows Calendar:** No Windows source is connected. This does not disconnect or alter Mac calendars.

Sync and real account acceptance require a later gated build, a registered callback, and Windows user interaction.
Preflight success and synthetic links are not Google sign-in or same-workspace convergence proof.
Automatic updates, Calendar connectors, and recovery for deleted Moves are not included.
Keep anything important in another system while testing this development build.

## One-time public setup preparation

1. Expand the workspace and select **Open setup folder**.
2. Copy the reviewed Windows `ProductAuth.local.json` into that folder.
3. Select **Reload setup**. Expect the account status to say it awaits exact Windows callback approval.

The file contains only schema version 1, the public Supabase endpoint, publishable key, and exact development callback.
Do not use the Mac configuration file unchanged. Do not add tokens, provider credentials, or a registration toggle.
The public setup file is intentionally absent from this bundle.
Configuration success is not sign-in proof. Do not attempt a live acceptance run while Google sign-in remains unavailable.

After Main integration approves the exact callback, use a separately identified, approved build for live testing.
That test needs the Windows user's browser interaction, durable sign-in, explicit workspace attachment, and exact Mac workspace-ID comparison.
Use a fresh Windows workspace to attach. Existing local data requires export-and-replace review and must not be silently overwritten.
Claiming a local workspace requires a reviewed name and explicit upload confirmation. Use only synthetic data.
No Calendar connection is created by product sign-in or workspace setup.
