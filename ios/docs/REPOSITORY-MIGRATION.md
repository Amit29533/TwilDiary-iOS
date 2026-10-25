# Complete iOS repository consolidation

26 October2026: the owner requested all native development, latest build,
backend/database source, workflows and supporting files move to
`Amit29533/TwilDiary-iOS`, usable as the primary project.

## What was imported

The complete tracked tree of original TwilDiary commit
`c14333f6e31473d6c428ab0b6640a6aa607a4657` was imported, **1,178entries**.
Import/ancestry commit`7dd0eff` has the identical tree
`3c7cbe7e7250e5c7e2348ad9892037c70be56def`. Both original histories are parents
or ancestors; no force push, shared reset or original main change is involved.
The previous destination tip`5d9cc2e` is retained at
`archive/pre-consolidation-ios`. Old root Swift project files are superseded by
the current`ios/`layout; their complete history remains available.

| Area | Paths in this repository |
| --- | --- |
|Native SwiftUI application, cache/auth/logic/resources|`ios/App`, `ios/Packages`, `ios/project.yml`|
|Native tests and disposable fixtures|`ios/Tests`, `ios/UITests`, package TestSupport/tests|
|Build/diagnostic/package/privacy/promotion tools|`ios/scripts`, `ios/tools`|
|Native and original design screenshots/evidence|`ios/docs/reference`, `ios/docs/screenshots`, `docs/screenshots`|
|Existing backend and complete API dependencies|`src`, `static`, `tooling`, root package/lockfile/configuration|
|D1 schema,17migrations and ORM metadata|`src/lib/server/db`, `drizzle`|
|Minute incoming Trakt Worker|`workers/trakt-incoming` including local/production configs and example variables|
|Backend/database/auth/Trakt tests|`tests` and SQLite/provider helpers|
|GitHub/Codemagic pipelines|`.github/workflows/ios.yml`, `repository.yml`, `codemagic.yaml`|
|Roadmap, progress, audits, requirements and rollout|`ROADMAP.md`, `PROGRESS.md`, `ios/docs`, `docs`|
|Deployment identity/config examples|`wrangler*.jsonc`, `.dev.vars.example`, incoming example/configuration|

The web UI source is included because the existing SvelteKit Worker builder and
shared business rules depend on it; it also preserves the parity reference.
No sibling/source checkout is needed for compilation or API tests.

`ios/docs/migration/source-inventory.json` records each imported path, Git blob
and mode. After the exact import, only the following original paths are adapted:
README.md, CODEMAGIC.md, PROGRESS.md, ROADMAP.md and .gitignore. The ignore file
also protects generated outputs from the historical root project. Original README/Codemagic
content is retained verbatim at`docs/WEB-BACKEND-README.md` and
`ios/docs/legacy-repository/CODEMAGIC-BEFORE-CONSOLIDATION.md`; progress/roadmap
history is retained alongside explicit current instructions. Added files provide
the new main-branch verification workflow, migration audit and actual62evidence.
Native/backend runtime source and existing native build gates remain unchanged.

## Latest source versus latest passed artifact

Main contains the latest native64development draft and its untested follow-up
fixes. It has **not** been compiled/run on macOS. The next-build hold remains;
moving source does not change its acceptance status.

The latest completely passed Codemagic build is native62, source`50134fc`.
Downloaded IPA and full source artifact archive were CRC/checksum-verified.
Actual logs show68Core,219native units,17focused,10early,53primary UI and3layout
cases each on17e/ProMax, with0native build warnings. The IPA contains the required
privacy manifest and no test fixtures. The independent original GitHub62run
failed four focused cases; this remains a **prerelease**, not stable acceptance.

The destination's[imported native62 prerelease](https://github.com/Amit29533/TwilDiary-iOS/releases/tag/native62-codemagic)
provides IPA/checksum/provenance and282exported screenshots/manifests/full logs.
Its tag points to the actual50134fcsource, not to the newer native64main.
Eight original passed screenshots and attachment digests are also committed under
`ios/docs/screenshots/step-10/build-62-codemagic-passed`.

## Repository and service cutover

- Main is current development. `repository.yml` checks Node24/API/database/Worker
  and Python tooling on Ubuntu using local fixtures, with no hosted credentials.
- The native `ios.yml` keeps official **same-repository/same-SHA** Codemagic proof,
  Core, native units, focused/full UI, extra phones, resource/privacy/warning and
  unsigned-device acceptance. Its trigger remains`ios-native`plus manual dispatch,
  which can target an accepted main SHA. Imported old-repo checks cannot qualify
  a new commit. No gate is weakened to make the migration green.
- Codemagic YAML is complete and manual-only. Its existing GitHub connection
  currently exposes only old TwilDiary. The owner must finish GitHub's email/sudo
  verification and add only TwilDiary-iOS to that existing installation before
  creating the destination application and posting official checks here. No
  permission expansion, new key/token, subscription or build is performed silently.
- Original candidate/stability refs are retained as archival branches, avoiding
  automatic Mac runs on an unqualified imported SHA. The consolidation head uses
  `[skip ci]`; no new candidate run is started merely to move files.
- Production Worker/D1/Access, provider redirect URIs, native bundle ID and endpoint
  stay the same. GitHub/Codemagic connection settings are external account state,
  not files that Git can copy. All database/API source is present; hosted data and
  provider credentials remain on Cloudflare. No data export, migration, deployment
  or paid-plan change follows from this migration.

## Verification in the destination checkout

- Exact initial import tree equality and full per-path source inventory.
- `npm ci`from the destination lockfile; audit0vulnerabilities.
-409NodeAPI/database/shared-rule tests pass,27release/migration-tool tests pass.
-`npm run check`:0errors/0warnings; incoming Worker TypeScript passes.
-`npm run build`:successful independent Worker build. The local Node process
  retains its existing NO_COLOR/FORCE_COLOR environment notice.
- All17migration files/snapshots/journal, native/Core/test resources, workflow
  references and root-relative build paths checked in this checkout.
- Fresh remote fetch and remote per-path blob verification after push, both
  history ancestry checks, release asset download/checksum and clean worktree.
  Machine-readable results are in`ios/docs/migration/verification.json`.

This verifies completeness/portability of the migration and the executed local
checks. It does not manufacture a macOS64pass, erase the existing CI failures,
certify Free-tier production usage or finish the remaining physical-phone audit.
