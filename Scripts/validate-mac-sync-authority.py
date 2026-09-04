#!/usr/bin/env python3

"""Fail CI if the Mac customer app regains a competing CloudKit authority."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parent.parent
RETIRED_RUNTIME_KEYS = {
    "FounderOfficeCloudEnabled",
    "FounderOfficeCloudContainerIdentifier",
}
RETIRED_ENTITLEMENTS = {
    "aps-environment",
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
}


def load_plist(path: Path) -> dict[str, object]:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise SystemExit(f"{path.name} must contain a dictionary")
    return value


def main() -> None:
    info = load_plist(ROOT / "Apps/macOS/Info.plist")
    entitlements = load_plist(ROOT / "Apps/macOS/FoundersOfficeMac.entitlements")

    runtime_keys = sorted(RETIRED_RUNTIME_KEYS.intersection(info))
    if runtime_keys:
        raise SystemExit(
            "Mac customer Info.plist contains retired CloudKit keys: "
            + ", ".join(runtime_keys)
        )

    entitlement_keys = sorted(RETIRED_ENTITLEMENTS.intersection(entitlements))
    if entitlement_keys:
        raise SystemExit(
            "Mac customer target contains retired CloudKit/push entitlements: "
            + ", ".join(entitlement_keys)
        )

    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    try:
        mac_target = project.split("  FoundersOfficeMac:\n", 1)[1].split(
            "\n  FoundersOfficeMacUITests:\n", 1
        )[0]
    except IndexError as error:
        raise SystemExit("Could not isolate the FoundersOfficeMac target") from error
    if "product: FounderOfficeCloud" in mac_target:
        raise SystemExit("Mac customer target still links the retired CloudKit module")

    for source in sorted((ROOT / "Sources/OpenLoops").glob("*.swift")):
        contents = source.read_text(encoding="utf-8")
        if "import FounderOfficeCloud" in contents or "CloudSyncBridge" in contents:
            raise SystemExit(f"Mac customer source restores a CloudKit writer: {source.name}")

    print("Mac customer sync authority is Supabase-only; CloudKit remains migration-only.")


if __name__ == "__main__":
    main()
