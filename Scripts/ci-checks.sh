#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 -m py_compile Scripts/openloops.py
swift run FounderOfficeCoreChecks
swift build -c release
swift Scripts/validate-notch-transparency.swift
swiftc -frontend -parse Apps/iOS/*.swift
swift Scripts/validate-motion.swift
plutil -lint \
    Resources/Info.plist \
    Apps/macOS/Info.plist \
    Apps/macOS/FoundersOfficeMac.entitlements \
    Apps/macOS/PrivacyInfo.xcprivacy \
    Apps/iOS/Resources/Info.plist \
    Apps/iOS/Resources/FoundersOfficeiOS.entitlements \
    Apps/iOS/Resources/PrivacyInfo.xcprivacy

echo "CI checks passed."
