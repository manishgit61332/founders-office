#!/usr/bin/env python3

"""Keep the installed development app and Xcode Mac target on one version."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parent.parent
PLISTS = (
    ROOT / "Apps/macOS/Info.plist",
    ROOT / "Resources/Info.plist",
)


def version(path: Path) -> tuple[str, str]:
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    marketing = payload.get("CFBundleShortVersionString")
    build = payload.get("CFBundleVersion")
    if not isinstance(marketing, str) or not isinstance(build, str):
        raise SystemExit(f"{path.relative_to(ROOT)} has no complete app version")
    return marketing, build


expected = version(PLISTS[0])
for path in PLISTS[1:]:
    actual = version(path)
    if actual != expected:
        raise SystemExit(
            f"Mac app version drift: {PLISTS[0].relative_to(ROOT)}={expected[0]} "
            f"({expected[1]}), {path.relative_to(ROOT)}={actual[0]} ({actual[1]})"
        )

print(f"Verified one Mac app version: {expected[0]} (build {expected[1]})")
