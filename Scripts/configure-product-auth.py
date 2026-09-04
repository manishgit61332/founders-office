#!/usr/bin/env python3
"""Validate and embed public product-auth settings before signing a local app."""

import argparse
import base64
import json
import pathlib
import plistlib
import re
import sys
from urllib.parse import urlsplit


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Product-auth configuration contains duplicate fields.")
        result[key] = value
    return result


def configuration(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError("Product-auth configuration must be a regular file.")
    if path.stat().st_size > 16_384:
        raise ValueError("Product-auth configuration is too large.")
    value = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicate_keys,
    )
    allowed = {"supabaseURL", "publishableKey", "callbackURL", "appleSignInEnabled"}
    if not isinstance(value, dict) or set(value) - allowed:
        raise ValueError("Product-auth configuration contains unsupported fields.")
    endpoint, key, callback = (value.get(name) for name in (
        "supabaseURL", "publishableKey", "callbackURL"
    ))
    if not all(isinstance(item, str) and item.strip() == item and item for item in (endpoint, key, callback)):
        raise ValueError("Product-auth public settings are incomplete.")
    parsed = urlsplit(endpoint)
    hostname = parsed.hostname or ""
    if (parsed.scheme != "https" or not parsed.hostname
            or not re.fullmatch(r"[a-z0-9]{20}\.supabase\.co", hostname)
            or parsed.username or parsed.password or parsed.port
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("Use an exact HTTPS Supabase project origin.")
    if (len(key) > 4096 or any(character.isspace() for character in key)
            or "placeholder" in key.lower() or "$(" in key
            or key.startswith("sb_secret_")):
        raise ValueError("A valid publishable client key is required.")
    if key.startswith("sb_publishable_"):
        valid_key = len(key) >= 20
    else:
        parts = key.split(".")
        try:
            payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            valid_key = len(parts) == 3 and payload.get("role") == "anon"
        except (IndexError, ValueError, AttributeError):
            valid_key = False
    if not valid_key:
        raise ValueError("Only a publishable or anonymous client key may enter the app.")
    if callback not in ("founders-office://auth/callback", "founders-office-dev://auth/callback"):
        raise ValueError("Use a supported product-auth callback.")
    apple = value.get("appleSignInEnabled", False)
    if not isinstance(apple, bool):
        raise ValueError("appleSignInEnabled must be a boolean.")
    return {
        "FounderOfficeSupabaseURL": endpoint,
        "FounderOfficeSupabasePublishableKey": key,
        "FounderOfficeAuthCallbackURL": callback,
        "FounderOfficeAppleSignInEnabled": apple,
        "CFBundleURLTypes": [{
            "CFBundleURLName": "FounderOfficeProductAuth",
            "CFBundleURLSchemes": [urlsplit(callback).scheme],
        }],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=pathlib.Path)
    parser.add_argument("--plist", type=pathlib.Path)
    args = parser.parse_args()
    try:
        settings = configuration(args.config)
        if args.plist:
            original = plistlib.loads(args.plist.read_bytes())
            original.update(settings)
            args.plist.write_bytes(plistlib.dumps(original, sort_keys=False))
    except (OSError, ValueError, TypeError, KeyError):
        # Never echo file contents or credential values in build output.
        print("Product-auth configuration rejected. Check the local public settings file.", file=sys.stderr)
        return 1
    print("Public product-auth configuration verified." if not args.plist else "Public product-auth configuration embedded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
