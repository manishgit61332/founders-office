#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

python3 -m py_compile \
    Scripts/openloops.py \
    Scripts/test-openloops-cli.py \
    Scripts/release_evidence_policy.py \
    Scripts/record-macos-clean-acceptance.py \
    Scripts/prepare-website-mac-release.py \
    Scripts/validate-sync-contracts.py \
    Scripts/verify-app-version.py \
    Scripts/verify-privacy-manifest.py
python3 Scripts/test-openloops-cli.py
python3 Scripts/verify-app-version.py
Scripts/validate-sync-contracts.py
bash -n \
    Scripts/check-repository-safety.sh \
    Scripts/ci-checks.sh \
    Scripts/verify-customer-binary-policy.sh \
    Scripts/verify-macos-ci-release.sh
zsh -n \
    Scripts/build-app.sh \
    Scripts/install-source-preview.sh \
    Scripts/release-macos.sh \
    Scripts/verify-macos-release.sh \
    Scripts/test-release-safety.sh
Scripts/test-release-safety.sh
Scripts/verify-privacy-manifest.py Apps/macOS/PrivacyInfo.xcprivacy
swift test --enable-code-coverage --skip WorkspaceRepositoryPerformanceTests
performance_test_status=1
for performance_test_attempt in 1 2 3; do
    echo "Running repository performance gate (attempt ${performance_test_attempt}/3)."
    if swift test \
        -c release \
        --scratch-path .build/performance \
        -Xswiftc -DFOUNDER_OFFICE_TESTING \
        --filter WorkspaceRepositoryPerformanceTests; then
        performance_test_status=0
        break
    fi

    if [[ "${performance_test_attempt}" -lt 3 ]]; then
        echo "Repository performance gate missed its unchanged budget; retrying the executable benchmark." >&2
    fi
done
if [[ "${performance_test_status}" -ne 0 ]]; then
    echo "Repository performance gate failed all three attempts." >&2
    exit "${performance_test_status}"
fi
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
