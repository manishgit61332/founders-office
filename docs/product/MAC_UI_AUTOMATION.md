# Mac UI automation

## Scope

`FoundersOfficeMacUITests` exercises the release-gate paths that require a real AppKit/SwiftUI process:

- clean first-run onboarding opening at its full 720×500 size, with its title,
  name field, and primary action all visible and hittable, plus 1× and 2×
  alpha-silhouette checks that keep every exterior corner transparent;
- Appearance edit → Save Changes → relaunch, plus forced relaunch without
  saving to prove that a draft never leaks into durable state;
- Discard, in-notch Escape, and explicit-notch-close Cancel with an unsaved
  Appearance draft;
- Move priority and deadline editing, plus a real long-list priority drag that
  holds at the viewport edge, auto-scrolls to an initially hidden lane, drops,
  and verifies the saved priority after relaunch;
- Calendar event creation in the top-layer editor;
- native colour-panel close or Escape → notch restoration, including with
  Reduce Motion and Reduce Transparency enabled; and
- Account & Sync remaining local-only, with no sign-in action or live-sync
  claim, when reviewed product configuration is absent; and
- preview of every redacted support-report field before Save.

The non-distribution `--ui-testing` launch hook uses a caller-provided temporary workspace, bypasses onboarding and cloud transport, activates a deterministic synthetic Calendar, and opens the notch as an interactive window. A separate `--ui-testing-onboarding` hook uses an isolated UserDefaults suite, temporary workspace, synthetic Calendar, in-memory startup status, and no-op login-item setter so it can exercise a genuinely fresh setup without reading or changing the developer's real onboarding record or system integrations. `OPENLOOPS_UI_TEST_FIXTURE=1` creates one synthetic Move only inside that temporary workspace. `OPENLOOPS_UI_TEST_LONG_PRIORITY_FIXTURE=1` creates an overflowing deterministic board for stationary-pointer edge-scroll and durable-drop coverage. The reduced-effects scenarios use `OPENLOOPS_UI_TEST_REDUCE_MOTION` and `OPENLOOPS_UI_TEST_REDUCE_TRANSPARENCY`; `FOUNDER_OFFICE_DISTRIBUTION` compiles all of these environment overrides out of the customer build.

## Generate and run

Use a logged-in Mac with full Xcode, then generate the project with XcodeGen
2.46.0 and run the same serial suite that CI runs:

```sh
xcodegen generate --spec project.yml
xcodebuild \
  -project FoundersOffice.xcodeproj \
  -scheme FoundersOfficeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/FoundersOffice-DerivedData-UI \
  -resultBundlePath /tmp/FoundersOfficeMacUITests.xcresult \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  test
```

Choose a result-bundle path that does not already exist.

That command uses the developer signing configured by Xcode. The credential-free
GitHub runner overrides the debug app to an ad-hoc signature and removes the
provisional product entitlements for this deterministic synthetic-data suite:

```sh
xcodebuild \
  -project FoundersOffice.xcodeproj \
  -scheme FoundersOfficeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/FoundersOffice-DerivedData-UI \
  -resultBundlePath /tmp/FoundersOfficeMacUITests.xcresult \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGN_ENTITLEMENTS='' \
  test
```

For a compile-only diagnostic that is **not** a release gate:

```sh
xcodebuild \
  -project FoundersOffice.xcodeproj \
  -scheme FoundersOfficeMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

The tests need an unlocked interactive macOS session with Accessibility
permission for the Xcode test runner. Founder’s Office assigns the owned native
colour panel a stable accessibility identifier while it is presented. If the
panel is not exposed, both required colour-panel scenarios fail; they never skip
or silently reduce the release gate to a compile check. GitHub Actions uploads
the failed `.xcresult` bundle for inspection.

## Current local verification gap

This repository was implemented on a host whose active developer directory is
Command Line Tools, not full Xcode. SwiftPM builds, strict-concurrency checks,
release builds, source parsing, and pure model tests run locally. XCUITest
execution is unavailable on that host. The workflow now invokes `xcodebuild
test` on its full-Xcode runner, but that runner result must exist and be green
before the Mac beta gate is accepted. Editing the workflow is not execution
evidence, and no local XCUITest pass is claimed.
