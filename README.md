# TwilDiary for iOS

This is the complete native SwiftUI application and its existing Cloudflare backend,
consolidated from [TwilDiary](https://github.com/Amit29533/TwilDiary). A fresh clone
contains the native app, API/Worker source, incoming Trakt scheduler, all 28 D1
migrations (through 0027), tests, fixtures, design references, deployment tools and both CI pipelines.
No sibling checkout is required to build either the iOS client or backend.

## Current development and builds

- `build/all-latest`: current development, merged into `main` by pull request.
- iPhone builds run on Namespace. A `namespace-ipa-<short sha>` tag builds the unsigned IPA and runs
  the core package tests ([ios-namespace-ipa.yml](.github/workflows/ios-namespace-ipa.yml)); a
  `namespace-check-<short sha>` tag runs the app's unit and UI checks
  ([ios-namespace-checks.yml](.github/workflows/ios-namespace-checks.yml)). Each run keeps its IPA
  and SHA256 as artifacts.
- History: the Codemagic native62–native64 candidates and earlier phone feedback are in
  [PROGRESS.md](PROGRESS.md) and [ROADMAP.md](ROADMAP.md). Both repositories' histories are
  preserved; the old root-level Swift project is reachable from the
  `archive/pre-consolidation-ios` tag and the merge ancestry.

## Build the native application

Windows has no Xcode. Use the Namespace tags above (Codemagic remains available; its setup and
provider connection requirements are in [CODEMAGIC.md](CODEMAGIC.md)).

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
credentials. All migration SQL and metadata are present through 0027. Which of them
hosted D1 has applied is checked there, not assumed from this list; follow
[the rollout runbook](ios/docs/BACKEND-ROLLOUT.md). Keep this project on Free and
verify actual account usage; local test results do not certify production costs.

## Pipelines and repository cutover

- `repository.yml`: inexpensive Node/API/database/release-tool verification for
  `main`, `develop` and pull requests; all database/provider tests use local fixtures.
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
