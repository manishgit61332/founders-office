# Mac UI automation

## Scope

`FoundersOfficeMacUITests` exercises the release-gate paths that require a real AppKit/SwiftUI process:

- Appearance edit → Save Changes → relaunch, plus forced relaunch without
  saving to prove that a draft never leaks into durable state;
- Discard, in-notch Escape, and explicit-notch-close Cancel with an unsaved
  Appearance draft;
- Move priority and deadline editing;
- Calendar event creation in the top-layer editor;
- native colour-panel close or Escape → notch restoration, including with
  Reduce Motion and Reduce Transparency enabled; and
- preview of every redacted support-report field before Save.

The non-distribution `--ui-testing` launch hook uses a caller-provided temporary workspace, bypasses onboarding and cloud transport, activates a deterministic synthetic Calendar, and opens the notch as an interactive window. `OPENLOOPS_UI_TEST_FIXTURE=1` creates one synthetic Move only inside that temporary workspace. The reduced-effects scenarios use `OPENLOOPS_UI_TEST_REDUCE_MOTION` and `OPENLOOPS_UI_TEST_REDUCE_TRANSPARENCY`; `FOUNDER_OFFICE_DISTRIBUTION` compiles all of these environment overrides out of the customer build.

## Generate and run

Use full Xcode and the pinned XcodeGen version from CI:

```sh
xcodegen generate --spec project.yml
xcodebuild \
  -project FoundersOffice.xcodeproj \
  -scheme FoundersOfficeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

For a compile-only gate:

```sh
xcodebuild \
  -project FoundersOffice.xcodeproj \
  -scheme FoundersOfficeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

The tests need an unlocked interactive macOS session with Accessibility permission for the Xcode test runner. The native colour-panel scenario skips, with a reason, when the SDK does not expose `NSColorPanel` as an accessibility window.

## Current local verification gap

This repository was implemented on a host whose active developer directory is Command Line Tools, not full Xcode. SwiftPM builds, strict-concurrency checks, release builds, source parsing, and pure model tests run locally. The pinned XcodeGen binary generated the project locally and the generated Mac scheme includes `FoundersOfficeMacUITests`. The `XCTest` module, `xcodebuild build-for-testing`, and XCUITest execution are unavailable without full Xcode. They must run on the full-Xcode CI runner or a development Mac before the Mac beta gate is accepted. No local XCUITest pass is claimed.
