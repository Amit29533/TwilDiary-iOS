# Native iOS builds on Codemagic

On25October local time the user explicitly authorized concurrent providers. First Codemagic run [6add160a4a72334e32e4d39f](https://codemagic.io/app/6adcc927390bc3069c9e5490/build/6add160a4a72334e32e4d39f) checks out72f081cf59b13f23a17fb4626cef522222ff2b94, the native build32 source. Its M2 baseline runs while the next GitHub revision is prepared; completion/results/artifacts remain pending. Earlier setup checkpoints below are historical, not the current run state. No billing/signing/publishing/SSH settings changed.


GitHub Actions on `ios-native` remains the established pipeline. The user additionally permits Codemagic; root `codemagic.yaml` prepares a **manual-only** fallback. The user has linked Codemagic app `6adcc927390bc3069c9e5490` to `Amit29533/TwilDiary`. Its authenticated browser settings now select `ios-native` and recognize the committed YAML, showing Start your first build. No Codemagic run or successful artifact is claimed; the current GitHub build is allowed to finish without duplicate execution. No API token was requested, read or stored. Do not cancel an active GitHub run or use a second provider to bypass a failing test.

To use the linked app, manually select branch `ios-native` and workflow `native-ios-regression`. It uses the standard M2 instance, pins Xcode 26.6 and reuses `ios/project.yml` plus **all** stages of `ios/scripts/ci.sh`: inventory, Core, simulator compile, early device regressions, unsigned arm64 Release, primary unit/UI, compact/large layout, screenshots and zero-warning diagnostics. The script derives simulator architecture from the machine, so an Apple silicon simulator build is distinct from the physical arm64 IPA. No signing credentials, Apple Developer membership, new subscription, deployment or production diary access is configured.

The first actual run must confirm Xcode/tool versions, simulator inventory, Bash execution, all test counts, logs, exported screenshot/xcresult artifacts and the IPA build/hash/architecture before acceptance. The EXIT trap retains diagnostics and preserves the original failing exit status; an unsigned IPA produced before later tests fail is only a diagnostic/trial artifact. Do not call it a passed release. GitHub-specific `collect-build.py` run metadata cannot be fabricated for Codemagic; provider-specific completed-run provenance must be recorded before accepting its artifacts. No UI, domain behavior, API or server changes are involved in this fallback configuration.

From build 30, `test-unit` runs before the early UI gate; `test` runs the complete primary UI suite. The manual fallback includes both stages and retains their separate xcresult/log evidence. This ordering does not bypass any failed test. No Codemagic execution has been started.

Official references checked on 24 October 2026:

- [Xcode 26.6 machine specifications](https://docs.codemagic.io/specs-macos/xcode-26-6/) list iOS 26.5 with iPhone 17 Pro, 17e and 17 Pro Max.
- [YAML workflows and instance configuration](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/).
- [CM_ENV propagation](https://docs.codemagic.io/yaml-basic-configuration/using-environment-variables/). The shared inventory stage's GITHUB_ENV output is mapped to CM_ENV, and this script also loads the simulator ID explicitly for its own shell.

Leave automatic triggering and publishing unset. If Codemagic is already linked elsewhere, reuse that application rather than creating duplicate integrations. Account linking/access is an external setup prerequisite, not a reason to stop the working GitHub pipeline.
