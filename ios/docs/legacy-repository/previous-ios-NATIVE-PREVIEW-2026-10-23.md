# First native iOS preview

The SwiftUI app is maintained in this separate repository. The existing web app, Cloudflare backend and live diary remain in [TwilDiary](https://github.com/Amit29533/TwilDiary). This is an initial native preview, not complete feature parity with the audited web release.

## Verified build

- App source: `0330361b1a17914298a571f72bab903e2842bce9`.
- [GitHub Actions run 39981870778](https://github.com/Amit29533/TwilDiary-iOS/actions/runs/39981870778) completed successfully using Xcode 26.6 / Swift 6.3.3 on macOS 26.
- Seven Swift package tests passed, including real workspace JSON decoding, rewatch deduplication, incomplete-catalogue time estimates, deleted titles, local-midnight boundaries and Monday-start weeks.
- Both native UI tests passed on iPhone 17 Pro: Library search/state across tab switches, Home → Library → title → back → Glance → Stats → More.
- Simulator Debug and physical-device Release compilation passed. No Apple account/certificate was used in CI.
- Six original simulator screenshots were exported and visually reviewed: Home, Library, title detail, Glance, Stats and More. See the run's Screenshots artifact. Its retention is seven days.

## LiveContainer download

The **TwilDiary-LiveContainer-IPA** artifact contains the unsigned device IPA and checksum. It is retained for fourteen days. Import the IPA inside the artifact ZIP into your configured LiveContainer. This is an arm64 iOS device application, with minimum iOS 26.0; it is not a simulator application or an Apple-provisioned installation.

SHA-256 for the IPA produced by this run:

```text
4860605a8b4a635661f1dd44cd3dd13271be4025a0d43ebaee9e887b3db17b3d
```

The downloaded archive's checksum matched the generated checksum, and its `Payload/TwilDiary.app/Info.plist`, bundle identifier (`com.amit29533.TwilDiary`) and arm64 Mach-O executable were checked independently.

## Limits and next work

CI uses synthetic fixtures. It does not log into the owner's Cloudflare account or make live diary/Trakt changes. Physical LiveContainer launching, Cloudflare sign-in and native mutation flows still require device verification. An embedded-browser login provider may require a later system-browser authentication bridge.

The remaining feature matrix is in [README](../README.md#port-coverage). Visual follow-up includes keeping the Library order label on one line, top-aligning cards with different title lengths, and matching the remaining Home and Stats details. The screenshots establish an initial layout baseline; they do not certify every font size, device or gesture. Xcode emitted an iPad orientation warning and the expected unused-AppIntents metadata notice; compilation and tests succeeded.

Simulator cold startup took several minutes. The workflow packages and uploads the device IPA before simulator startup so that a simulator delay does not withhold the device artifact.
