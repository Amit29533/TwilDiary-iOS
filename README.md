# TwilDiary for iOS

This is the complete native SwiftUI application and its existing Cloudflare backend,
consolidated from [TwilDiary](https://github.com/Amit29533/TwilDiary). A fresh clone
contains the native app, API/Worker source, incoming Trakt scheduler, all17D1
migrations, tests, fixtures, design references, deployment tools and both CI pipelines.
No sibling checkout is required to build either the iOS client or backend.

## Current development and builds

- `main`: latest development source, including the prepared native64changes.
  Native64has not compiled/run on macOS yet; migration is not a stability claim.
- Latest completed Codemagic build: **native62**, source`50134fc`. Its imported
  unsigned iPhone IPA, SHA256 and test evidence are in the
  [native62 prerelease](https://github.com/Amit29533/TwilDiary-iOS/releases/tag/native62-codemagic).
  Its independent original GitHub iOS run failed; read its provenance before testing.
- Native63failed its cold-quota Pause UI case. Native64and all outstanding phone
  feedback remain in [PROGRESS.md](PROGRESS.md); the ten-step audit is in [ROADMAP.md](ROADMAP.md).
- Both repositories' histories are preserved. The old root-level Swift project
  is superseded by `ios/`; historical source is reachable from the
  `archive/pre-consolidation-ios` tag and the merge ancestry.

## Build the native application

Windows has no Xcode. Use the manually started Codemagic candidate workflow, then
independent GitHub verification of that **same SHA**. Build setup and provider
connection requirements are in [CODEMAGIC.md](CODEMAGIC.md).

On a Mac with the pinned Xcode26.6/iOS26.5 toolchain:

```sh
bash ios/scripts/xcodegen.sh
swift test --package-path ios/Packages/TwilDiaryCore
bash ios/scripts/ci.sh inventory
```

`ios/project.yml` is the XcodeGen project source. Generated `.xcodeproj`, compiled
outputs and certificates stay out of Git. The app targets iPhone/iOS26+; its
configured endpoint and bundle ID remain unchanged. Install the unsigned IPA
using your existing LiveContainer setup; see
[installation](ios/docs/INSTALL-WITHOUT-MAC.md) and [device checks](ios/docs/DEVICE-CHECKS.md).

## Backend and database, independently from this clone

Requires Node24+. These commands use a disposable local database, never hosted D1:

```sh
npm ci
npm run check
npm test
npm run build
npm run db:migrate:local
```

For a local API server, copy `.dev.vars.example` to ignored `.dev.vars`, set
`LOCAL_DIARY=1`, then `npm run dev`. Live provider credentials are optional for
fixture-backed tests and must never be committed. See
[original backend setup](docs/WEB-BACKEND-README.md) and
[architecture](ios/docs/IOS-ARCHITECTURE.md).

`wrangler.production.jsonc` and `workers/trakt-incoming/wrangler.production.jsonc`
identify the **existing** hosted D1/Workers. The consolidation creates no database,
clones no hosted data, changes no Access policy, deploys nothing and copies no
credentials. All migration SQL and metadata are present through0016. The tested
0014–0016rollout is still pending on hosted D1; follow
[the rollout runbook](ios/docs/BACKEND-ROLLOUT.md). Keep this project on Free and
verify actual account usage; local test results do not certify production costs.

## Pipelines and repository cutover

- `repository.yml`: inexpensive Node/API/database/release-tool verification for
  `main` and pull requests; all database/provider tests use local fixtures.
- `codemagic.yaml`: manual-only full native candidate regression and separate
  explicitly labelled phone diagnostic. No automatic builds or deployment.
- `ios.yml`: independent macOS verification, triggered on `ios-native` or manually
  on a fully Codemagic-qualified SHA. Official checks must belong to this repository;
  historical checks from the original repository cannot qualify a new commit.
- No CI workflow deploys Cloudflare, signs an app or uses hosted diary credentials.

The import commit uses `[skip ci]` to preserve the requested next-build hold.
The latest development is not automatically promoted to `ios-native`.
See [migration inventory and verification](ios/docs/REPOSITORY-MIGRATION.md),
[parity](ios/docs/IOS-PARITY.md), and [release provenance](ios/docs/releases/).
