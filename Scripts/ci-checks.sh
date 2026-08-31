#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 -m py_compile \
    Scripts/openloops.py \
    Scripts/test-openloops-cli.py \
    Scripts/record-macos-clean-acceptance.py \
    Scripts/prepare-website-mac-release.py \
    Scripts/validate-sync-contracts.py \
    Scripts/verify-privacy-manifest.py
python3 Scripts/test-openloops-cli.py
Scripts/validate-sync-contracts.py
bash -n \
    Scripts/check-repository-safety.sh \
    Scripts/ci-checks.sh \
    Scripts/verify-customer-binary-policy.sh \
    Scripts/verify-macos-ci-release.sh
zsh -n Scripts/build-app.sh Scripts/release-macos.sh Scripts/verify-macos-release.sh Scripts/test-release-safety.sh
Scripts/test-release-safety.sh
Scripts/verify-privacy-manifest.py Apps/macOS/PrivacyInfo.xcprivacy
swift test --enable-code-coverage
swift run FounderOfficeCoreChecks
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift build -c release
swift build \
    -c release \
    --scratch-path .build/distribution-policy \
    -Xswiftc -DFOUNDER_OFFICE_DISTRIBUTION \
    -Xswiftc -warnings-as-errors
Scripts/verify-customer-binary-policy.sh .build/distribution-policy/release/OpenLoops
swift Scripts/validate-notch-transparency.swift
swiftc -frontend -parse Apps/macOSUITests/*.swift
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
