#!/usr/bin/env python3

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"verify-privacy-manifest.py: {message}")


def load_json_without_duplicates(path: Path) -> dict[str, object]:
    def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                fail(f"policy contains duplicate key: {key}")
            result[key] = value
        return result

    with path.open(encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=reject_duplicates)
    if not isinstance(value, dict):
        fail("policy root must be an object")
    return value


def require_regular_small_file(path: Path, label: str) -> None:
    try:
        stat_result = path.lstat()
    except OSError as error:
        fail(f"cannot read {label}: {error.strerror}")
    if path.is_symlink() or not path.is_file():
        fail(f"{label} must be a regular non-symlink file")
    if stat_result.st_size > 1_048_576:
        fail(f"{label} exceeds the 1 MiB safety limit")


def normalized_accessed_types(value: object, label: str) -> list[dict[str, object]]:
    if not isinstance(value, list):
        fail(f"{label} accessed API types must be an array")
    normalized: list[dict[str, object]] = []
    seen_categories: set[str] = set()
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
        }:
            fail(f"{label} contains a malformed accessed API entry")
        category = entry["NSPrivacyAccessedAPIType"]
        reasons = entry["NSPrivacyAccessedAPITypeReasons"]
        if not isinstance(category, str) or not category:
            fail(f"{label} contains an invalid accessed API category")
        if category in seen_categories:
            fail(f"{label} repeats accessed API category: {category}")
        if (
            not isinstance(reasons, list)
            or not reasons
            or any(not isinstance(reason, str) or not reason for reason in reasons)
            or len(reasons) != len(set(reasons))
        ):
            fail(f"{label} contains invalid reasons for: {category}")
        seen_categories.add(category)
        normalized.append({"category": category, "reasons": sorted(reasons)})
    return sorted(normalized, key=lambda item: str(item["category"]))


def normalized_policy_accessed_types(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        fail("policy accessed API types must be an array")
    converted: list[dict[str, object]] = []
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {"category", "reasons"}:
            fail("policy contains a malformed accessed API entry")
        converted.append(
            {
                "NSPrivacyAccessedAPIType": entry["category"],
                "NSPrivacyAccessedAPITypeReasons": entry["reasons"],
            }
        )
    return normalized_accessed_types(converted, "policy")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: verify-privacy-manifest.py <PrivacyInfo.xcprivacy>")

    manifest_path = Path(sys.argv[1])
    project_root = Path(__file__).resolve().parent.parent
    policy_path = project_root / "Config" / "Release" / "PrivacyManifestPolicy.json"
    require_regular_small_file(manifest_path, "privacy manifest")
    require_regular_small_file(policy_path, "reviewed privacy policy")

    policy = load_json_without_duplicates(policy_path)
    if set(policy) != {
        "schemaVersion",
        "tracking",
        "trackingDomains",
        "collectedDataTypes",
        "accessedAPITypes",
    }:
        fail("reviewed privacy policy has missing or unexpected fields")
    if policy["schemaVersion"] != 1:
        fail("reviewed privacy policy schema is unsupported")
    if policy["tracking"] is not False:
        fail("reviewed privacy policy must disable tracking")
    if policy["trackingDomains"] != [] or policy["collectedDataTypes"] != []:
        fail("reviewed privacy policy must declare no tracking domains or collected data")

    try:
        with manifest_path.open("rb") as handle:
            manifest = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"privacy manifest is not a valid plist: {error}")
    if not isinstance(manifest, dict):
        fail("privacy manifest root must be a dictionary")
    allowed_keys = {
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyAccessedAPITypes",
    }
    unexpected = sorted(set(manifest) - allowed_keys)
    if unexpected:
        fail("privacy manifest has unexpected keys: " + ", ".join(unexpected))
    if manifest.get("NSPrivacyTracking") is not False:
        fail("privacy manifest must explicitly disable tracking")
    if manifest.get("NSPrivacyTrackingDomains", []) != []:
        fail("privacy manifest tracking domains differ from reviewed policy")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        fail("privacy manifest collected data differs from reviewed policy")

    actual_accessed = normalized_accessed_types(
        manifest.get("NSPrivacyAccessedAPITypes"),
        "privacy manifest",
    )
    expected_accessed = normalized_policy_accessed_types(policy["accessedAPITypes"])
    if actual_accessed != expected_accessed:
        fail("privacy manifest accessed API declarations differ from reviewed policy")

    print(f"Verified privacy manifest policy: {manifest_path}")


if __name__ == "__main__":
    main()
