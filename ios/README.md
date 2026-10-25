# TwilDiary native iPhone app

Current build source: **Amit29533/TwilDiary**, branch **ios-native**, directory **ios/**.

The web app on main is the design and behavior reference. The earlier Amit29533/TwilDiary-iOS repository is preserved unchanged; it is not the active build location for this branch.

- Project definition: project.yml (XcodeGen; generated Xcode project is ignored).
- Build workflow: ../.github/workflows/ios.yml.
- Current state and remaining work: ../PROGRESS.md and ../ROADMAP.md.
- Architecture: docs/IOS-ARCHITECTURE.md.
- Installation: docs/INSTALL-WITHOUT-MAC.md.
- Phone-only checks: docs/DEVICE-CHECKS.md.

All Swift compilation, simulator runs and XCTest/XCUITest execution happen on GitHub Actions macOS runners. No Mac or Xcode is required on the Windows development machine. The workflow publishes an unsigned physical-device IPA and simulator screenshots; it does not deploy the backend or sign/upload to the App Store.

Synthetic screenshots are selected only in Debug builds launched with --ui-testing. Release builds use the existing private backend and Keychain session. No credentials are committed or bundled.
