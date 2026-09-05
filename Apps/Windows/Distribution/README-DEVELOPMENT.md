# Founder's Office for Windows — DEVELOPMENT build

This bundle is for testing on Windows 11 build 22621 or later. It is not a
production beta and is not signed with the future production identity.

The MSIX is signed in GitHub Actions with a short-lived, self-signed development
certificate whose public half is included in this bundle. The private key is
destroyed with the build runner and is never included here.

## Install

1. Extract the complete ZIP. Do not run the installer from inside the ZIP.
2. Right-click `Install-Development.ps1`, choose **Run with PowerShell**, and
   approve the Current User certificate prompt if Windows shows one.
3. Open **Founder's Office** from Start.

If PowerShell blocks the downloaded script, open Properties for the ZIP, select
**Unblock**, extract it again, and rerun the installer. Organization-managed
Windows devices may disallow test certificates or sideloaded apps.

The installer verifies the included file hashes and confirms that the MSIX was
signed by the bundled certificate before it trusts that certificate for the
current Windows user. It does not request an administrator account.

## What to test

- Add a Move with a title, description, priority, and optional deadline.
- Edit those fields, then close and reopen the app to confirm persistence.
- Complete a Move, find it in Completed history, and reopen it.
- Hide and reopen the surface from the notification-area icon.
- Right-click the icon and test **Open/Hide** and **Exit**.

## One-time laptop check

Use this exact bundle on each Windows 11 x64 laptop. No developer tools, cloud VM, or Google login are needed.
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

- **Product account:** Google sign-in is not available in this Windows build.
- **Move sync:** Changes stay in this Windows user's private local app data.
- **Windows Calendar:** No Windows source is connected. This does not disconnect or alter Mac calendars.

Sync and real account acceptance require a later gated build, a registered callback, and Windows user interaction.
Preflight success and synthetic links are not Google sign-in or same-workspace convergence proof.
Automatic updates, Calendar connectors, and recovery for deleted Moves are not included.
Keep anything important in another system while testing this development build.
