#!/usr/bin/env python3
"""Executable checks for the public product-auth configuration boundary."""

import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("configure-product-auth.py")
VALID_CONFIGURATION = {
    "supabaseURL": "https://abcdefghijklmnopqrst.supabase.co",
    "publishableKey": "sb_publishable_12345678901234567890",
    "callbackURL": "founders-office://auth/callback",
}


class ConfigureProductAuthTests(unittest.TestCase):
    def run_script(self, configuration, *, plist=None, raw=None):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            config_path = root / "ProductAuth.local.json"
            config_path.write_text(
                raw if raw is not None else json.dumps(configuration),
                encoding="utf-8",
            )
            arguments = [sys.executable, str(SCRIPT), str(config_path)]
            plist_path = None
            if plist is not None:
                plist_path = root / "Info.plist"
                plist_path.write_bytes(plistlib.dumps(plist, sort_keys=False))
                arguments.extend(["--plist", str(plist_path)])
            result = subprocess.run(
                arguments,
                check=False,
                capture_output=True,
                text=True,
            )
            embedded = plistlib.loads(plist_path.read_bytes()) if plist_path else None
            return result, embedded

    def test_embeds_public_settings_and_disables_apple_by_default(self):
        result, embedded = self.run_script(
            VALID_CONFIGURATION,
            plist={"ExistingSetting": "preserved"},
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(embedded["ExistingSetting"], "preserved")
        self.assertEqual(
            embedded["FounderOfficeSupabaseURL"],
            VALID_CONFIGURATION["supabaseURL"],
        )
        self.assertEqual(
            embedded["FounderOfficeSupabasePublishableKey"],
            VALID_CONFIGURATION["publishableKey"],
        )
        self.assertEqual(
            embedded["FounderOfficeAuthCallbackURL"],
            VALID_CONFIGURATION["callbackURL"],
        )
        self.assertFalse(embedded["FounderOfficeAppleSignInEnabled"])
        self.assertEqual(
            embedded["CFBundleURLTypes"][0]["CFBundleURLSchemes"],
            ["founders-office"],
        )

    def test_apple_sign_in_requires_an_explicit_boolean(self):
        enabled = dict(VALID_CONFIGURATION, appleSignInEnabled=True)
        result, embedded = self.run_script(enabled, plist={})
        self.assertEqual(result.returncode, 0)
        self.assertTrue(embedded["FounderOfficeAppleSignInEnabled"])

        invalid = dict(VALID_CONFIGURATION, appleSignInEnabled="true")
        result, _ = self.run_script(invalid)
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_ambiguous_or_sensitive_configuration(self):
        rejected = [
            dict(VALID_CONFIGURATION, publishableKey="sb_secret_never_embed"),
            dict(VALID_CONFIGURATION, supabaseURL="https://example.com"),
            dict(
                VALID_CONFIGURATION,
                callbackURL="founders-office://auth/callback?unexpected=true",
            ),
            dict(VALID_CONFIGURATION, clientSecret="never-allowed"),
        ]
        for configuration in rejected:
            with self.subTest(configuration=sorted(configuration)):
                result, _ = self.run_script(configuration)
                self.assertNotEqual(result.returncode, 0)

        duplicate = (
            '{"supabaseURL":"https://abcdefghijklmnopqrst.supabase.co",'
            '"supabaseURL":"https://zyxwvutsrqponmlkjihg.supabase.co",'
            '"publishableKey":"sb_publishable_12345678901234567890",'
            '"callbackURL":"founders-office://auth/callback"}'
        )
        result, _ = self.run_script(None, raw=duplicate)
        self.assertNotEqual(result.returncode, 0)

    def test_rejection_never_echoes_the_rejected_value(self):
        sentinel = "do-not-print-this-value"
        invalid = dict(VALID_CONFIGURATION, publishableKey=sentinel)
        result, _ = self.run_script(invalid)

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(sentinel, result.stdout)
        self.assertNotIn(sentinel, result.stderr)


if __name__ == "__main__":
    unittest.main()
