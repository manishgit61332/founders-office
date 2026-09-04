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

Sync, account sign-in, automatic updates, Calendar connectors, and recovery for
deleted Moves are not included. Changes stay in the signed-in Windows user's
private local app data. Keep anything important in another system while testing
this development build.
