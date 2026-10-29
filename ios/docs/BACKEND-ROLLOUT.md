# Native client backend rollout — deployed 26 October 2026

## Rollout 0020 (incremental Trakt scans) — deployed 29 October 2026

Completed 00:12–00:14 UTC, right after the daily D1 reset. Main Worker
`da0273f3-ab8c-4ea4-a7f6-6aa11724525e` from `main` 9f4d93f (previous `736df176-…`), 100%;
the incoming worker is unchanged. Before: Time Travel bookmark
`000000bc-00000004-00005113-178f4ad145c976c898ab07755060a314`, a fresh private export
(35,986 rows), preflight (20 migrations, 17 objects, nothing written) and an offline
rehearsal of 0020 on that export (integrity ok, every original row preserved, review counts
exact). After: postflight 21 migrations, 36 objects, the five run columns, zero count
mismatches, one revision row, empty snapshot/checkpoint/journal/work tables; signed-out
requests still go to Cloudflare Access. The review left in `applying` from 28 Oct
(progress 3,692) finishes under the new code. Receipt:
[backend-0020-production-rollout.json](releases/backend-0020-production-rollout.json).
The preparation notes below are kept as the record of what was planned.


Source: `main` after PR #8. Hosted D1 has 0000–0019; the pending set must be exactly
`0020_trakt_incremental.sql`: four new empty tables (`trakt_snapshot`,
`trakt_sync_checkpoint`, `trakt_sync_journal`, `trakt_sync_work`), four nullable
`trakt_sync_runs` columns and 13 triggers that journal diary changes. Additive: the
current Worker keeps working against the new schema (the triggers only add journal
rows), so a code rollback needs no schema change.

Same procedure as below: record the main Worker version, fresh Time Travel bookmark
and export, `rehearse()` (the tool reviews 0014–0020), preflight (17 objects before),
apply, postflight (21 migrations, 36 objects, the five run columns, empty incremental
tables), then deploy the **main Worker only** (the incoming worker's code is
unchanged; its imports are journaled by the triggers).

After deploying: the first scan compares everything once and builds the snapshot. A
review still open from before the deploy completes normally; completing it writes its
stored records (about 3,700) into the snapshot once and requests one full scan. Deploy
early in the UTC day so that one-off write burst falls in a fresh daily allowance.

Local dress rehearsal (28 Oct, private): the morning export with 0017–0020 applied, the
new code and a fake Trakt serving that export's real records (2,039 plays, 155 ratings,
116 watchlist entries). Rows are D1 rows as metered by local workerd:

| Step | Requests | Rows read | Rows written |
| --- | --- | --- | --- |
| First scan after deploy (full) | 425 | 116k | 27k |
| Resolving that review (1,506 ready changes, 1,341 removals with Use Trakt) | 508 | 362k | 73k |
| Next scan (plans what the first one imported) | 78 | 51k | 0.8k |
| Later scans with 23 skipped items left | ~30 | ~13k | ~0.2k |
| One play added and one removed on Trakt, one watch logged | 36 | 26k | 0.3k |
| Requested full check | 361 | 193k | 0.6k |

Most of the review's writes are the imported titles' seasons and episodes, the plays and
their baselines. Skipped items are planned again on every scan by design.

## Planning CPU hotfix — deployed 28 October 2026

Main Worker `736df176-a76b-4c33-a4ac-0d927d5f9cb9` from PR #7 (`4f90bf6`), about
11:25 UTC, no migration: planning windows of 20 rows with at most one per-item merge
per request. Afterwards no request exceeded its CPU limit (the last
`exceededResources` was 11:22 UTC, before the deploy); CPU per step was about
9.5–11 ms at the median and 17 ms at p99 while a full scan compared history.

## Rollout 0017–0019 and main/incoming Workers — deployed 28 October 2026

Completed 10:48–10:58 UTC. Main Worker `0483e8d7-5335-4bef-9c17-ba5f7f7d9c73`
(previous `d21c2b88-…`), incoming worker `40e3d330-4b95-47c2-a393-62962c074c88`
(previous `3150a352-…`), both at 100%. Fresh bookmark and export, offline
rehearsal, postflight (20 migrations, 17 objects, zero mismatches, one revision
row), Access denial, a 93-request owner phone session and three idle scheduled
runs all passed. Receipt:
[backend-0017-0019-production-rollout.json](releases/backend-0017-0019-production-rollout.json).
The preparation notes below are kept as the record of what was planned.

Source: `main` after PRs #2–#5 (8f82b28 or later). Hosted D1 has 0000–0016; the
pending set must be exactly:

| Order | Migration | Result |
| --- | --- | --- |
|1|0017_trakt_import_indexes.sql|Six additive indexes (unconfirmed-send and local-event partial indexes, scanner/watch-operation lookups)|
|2|0018_trakt_remote_history_tmdb.sql|One partial expression index for the watchlist "already watched on Trakt" check|
|3|0019_workspace_revision.sql|New one-row `workspace_revision` table seeded with a random token|

All three are additive; the 26 October Worker version stays schema-compatible
for code rollback. Unlike that rollout, **both** Workers deploy this time: the
incoming worker now bumps the workspace revision after ticks that may import.

Follow the procedure below with these changes: record both Workers' current
versions, expect 0017–0019 pending, rehearse with `prepare-d1-rollout.py`'s
`rehearse()` (the tool now reviews 0014–0019), run the updated pre/postflight SQL
(postflight requires 20 migrations, 17 objects, zero bucket mismatches and one
32-hex revision row), deploy the main Worker, then
`npx wrangler deploy --config workers/trakt-incoming/wrangler.production.jsonc --keep-vars`.
Release gate for this backend rollout: GitHub Actions evidence on the merged
stack (backend verification green; native 53/54, the failure a known Undo-timing
flake) in place of a Codemagic check, by owner decision on 28 October 2026.

## Completed rollout and measured evidence

Deployed at 04:11:56 UTC (09:41 IST) on 26 October 2026 from the canonical
TwilDiary-iOS checkout. Frozen backend source remains 50134fc; new main Worker
version is `d21c2b88-a874-46fa-8dc4-61798d8544d8` at 100%. The prior version
`1dc0eced-83ac-4312-8d40-73aa6124cba5` is retained for code rollback.
The owner requested starting the planned setup; no additional approval is pending.

- Fresh private full SQL export (9,882,173 bytes) and Time Travel bookmark captured.
  Restoring/rehearsing the real export passes all schema, ledger, integrity,
  foreign-key, original-row and aggregate checks before hosted mutation.
- Exactly 0014–0016 applied. Hosted postflight verifies 17 migrations, all 9 expected
  objects, nullable TEXT `plan_after`, unchanged active review/incoming settings
  and zero counter mismatches. A fresh post-export independently verifies all
  original columns/rows across 26 application tables unchanged.
- Authenticated native session/review/incoming GETs succeed; unauthenticated
  session request is denied 403. Review remains 735 applied / 1474 pending /
  1466 safe / 1 link. Incoming is enabled and still paused by the existing review. No
  proposal was applied/skipped, no scheduler deployment and no new iOS build.
- Hosted equivalent-query samples read 8 rows for aggregate buckets, 1 for the next
  ready proposal and 40 for a 40-item seek page, with 0 writes. EXPLAIN confirms the
  expected indexes and no temporary sort. These samples exclude the rest of a
  complete API/apply path; no full-import throughput/CPU claim follows.
- Dashboard 00:00–04:16 UTC shows approximately 98k reads / 13k writes on the account's
  only database, including migration overhead. Diagnostic SQL used 12207 reads /
  0 writes; exports/DDL/provider API reads are additional rollout costs. Remaining
  sustained account-day and active scheduler CPU acceptance is still open.

Public receipt: [backend62-production-rollout.json](releases/backend62-production-rollout.json).
Private backups/bookmarks/operator logs and pinned source/build reside in ignored
`.local/cloudflare-rollout-20261026`. No backup or credential enters Git/CI.
The earlier preparation and repeatable operator procedure are retained below.

### Subsequent owner-authorized live apply sample

Applied exactly three ready incoming proposals: two episode histories and one
rating, using individual review controls against the protected deployed API.
All three became applied. Read-back confirms unique active watches with the
exact original Trakt timestamps/history identities and the expected saved
rating. Progress rose by three; only pending/applied incoming-safe buckets
changed, by minus/plus three. No errors or cooldown messages appeared. A fresh
recovery bookmark and all raw observations remain private.

No outgoing Trakt writes, conflict choices, uncertain retries or bulk loop were
started. These results do not certify native phone UI, restart recovery or the
remaining large import. Query analytics are aggregated across other traffic;
do not divide the rolling total by three and label it an import cost.
See [the redacted live receipt](releases/backend62-live-apply-verification.json).

Prepared 26 October 2026 IST for the D1 read amplification fixes. This is an
operator procedure, not an automatic deployment or an iOS build trigger.

## Frozen release

- Backend source: `50134fc9addcc243434ee5721eb74ea1eec13f61` (native62).
- Official complete Codemagic check: [121268303837](https://github.com/Amit29533/TwilDiary/runs/121268303837).
- Independent [GitHub run40228034161](https://github.com/Amit29533/TwilDiary/actions/runs/40228034161)
  passes its backend job:407contract tests, typecheck0errors/0warnings, Worker
  build. Its iOS focused suite **failed**; this is not a stable iOS release claim.
- Main Worker: `twildiary-v2`; D1: `twildiary-v2`,
  `fee4edca-0618-44fb-b110-0a9ecb3dfe17`.
- Last observed main Worker version: `1dc0eced-83ac-4312-8d40-73aa6124cba5`.
  Re-read the current deployment immediately before a real rollout; never assume
  the saved version is still current.
- Scheduled Worker `twildiary-trakt-incoming` is a separate deployment. Leave its
  existing version, secrets, Cron and opt-in alone in this rollout. These changes
  repair the main API's manual bulk review/planning queries.

Private prepared package and logs are under ignored
`.local/backend-rollout-native62-20261026`. `package/source.tar` is an exact Git
archive, not the newer untested native64 working tree. `package/manifest.json`
records source, official check, migration/dependency/config hashes, backend Git
tree identities and source archive checksum. The extracted source was installed
from its lockfile, built and Wrangler dry-run successfully. Dry-run reported one
`ignored-bare-import` warning for a generated `import "drizzle-orm"`; the package
declares no side effects. Retain that diagnostic; do not call it a zero-warning
Worker bundling run or alter the frozen release merely to silence it.

## Checks completed without hosted writes

1. `ios/tools/prepare-d1-rollout.py` requires a full immutable SHA and the latest
   official successful Codemagic check for that SHA. It never invokes Wrangler,
   deploys, runs remote SQL or opens a network connection.
2. A full SQL export restores into memory. Integrity/foreign keys, complete
   migration ledger and schema inventory must agree. Unknown/missing migrations
   or schema drift stop preparation. SQL cannot attach another database or load
   an extension; the input file remains untouched.
3. Pending0014–0016 apply to the memory copy. Every original column/row has the
   same count and SHA256 digest afterward, including credentials, timestamps,
   notes, Queue, favorites, receipts, revoked watches, review choices, incoming
   settings and acknowledgements.0015only adds nullable `plan_after`.
4. Rehearsal includes2,000proposals:600applied, a skipped item, an uncertain item
   and a conflict. It verifies existing aggregates after partial/already-complete
   upgrades and rejects corrupted counters or row-mutating migrations.
5. The same fixture was upgraded through0014–0016 in **Wrangler4.151.3 local
   D1/workerd**. Its real before/after SQL exports restore and match the memory
   rehearsal exactly:26original application tables,27after,2,000proposals and
   two preserved watches. Operator postflight SQL also executes in that runtime.
   This is local correctness evidence, not hosted row-cost/CPU/latency evidence.

## After quota recovery: read-only preparation first

The last hosted SQL attempt returned Cloudflare7500daily-read-quota. Metadata
authentication works. Free D1 resets at00:00UTC (05:30IST); verify recovery once
rather than repeatedly probing during exhaustion. Account-wide usage and other
traffic still matter after reset.

Run from the frozen extracted source. Use the explicit database name plus the
production config; confirm the UUID above in `d1 info` before any mutation. Keep
outputs in ignored private storage, never CI artifacts or public commits.

```powershell
npx wrangler d1 info twildiary-v2 --config wrangler.production.jsonc --json
npx wrangler deployments list --config wrangler.production.jsonc --json
npx wrangler d1 migrations list twildiary-v2 --remote --config wrangler.production.jsonc
```

Expect only0014,0015,0016pending, or a known contiguous prefix already applied.
An unexpected migration or changed target/version stops the rollout for source
reconciliation. Do not apply an unreviewed backlog with a blanket command.

Take a fresh Time Travel bookmark and a **full schema+data export** to new private
filenames. Export temporarily blocks database requests; schedule a short quiet
period. Do not delete virtual tables or strip production rows to force an export.

```powershell
npx wrangler d1 time-travel info twildiary-v2 --config wrangler.production.jsonc --json
npx wrangler d1 export twildiary-v2 --remote --config wrangler.production.jsonc --output ../private-before-rollout.sql
```

Retain the bookmark/time/actual Worker version privately. The prior backup is
historical and does not replace this fresh one. No SQL export or Time Travel
restore has been run against hosted D1 during this preparation.

Run the preparation tool from the task checkout, with fresh same-SHA check JSON,
the new private export and a **new** output directory:

```powershell
python ios/tools/prepare-d1-rollout.py --source 50134fc9addcc243434ee5721eb74ea1eec13f61 --checks .local/codemagic62-rollout-checks.json --backup .local/backend-rollout-native62-20261026/private-before-rollout.sql --output .local/verified-hosted-rollout
```

The export path assumes the working directory was the prepared `source` folder,
so `../private-before-rollout.sql` stays in the ignored preparation directory.
The tool rejects existing output directories, missing ledgers and
non-contiguous/unknown migrations. Re-fetch official checks first; a stored check
file is historical evidence, not a live provider query. Private reports include
table counts/digests only, never row contents. A successful rehearsal does not
prove the export's freshness; record its capture time separately.

Capture `ios/deploy/preflight-d1.sql` once with the production D1 CLI, redirecting
results to private storage. It is read-only and records the active review's
identity/stage/checkpoint/buckets and incoming configuration. Its one-time count
of active proposals is deliberate; do not put it on the minute/polling path.

Wrangler 4.151.3 `--file` uses the SQL ingestion path: its JSON contains aggregate
execution statistics, not the SELECT result rows needed for comparison. For
pre/postflight inspection use `--command=<SQL>` with comment lines removed, passing
the whole value as one subprocess argument. Capture stdout privately and validate
each result's `success`, `results` and `meta`; do not accept exit code alone. The
executed rollout used this result-returning path and compared actual rows before
deploying. A leading `--` comment must not be parsed as another CLI option.

## Apply database changes, then main API

Do this only after the backup/rehearsal/target checks above succeed. Do not run a
review apply/scan concurrently with migration. If the owner's import is actively
advancing, defer to a quiet point; do not cancel the run, disconnect, reset choices
or start another scan to manufacture a clean test. The parked manual review must
continue fencing scheduled imports.

| Order | Migration | Result |
| --- | --- | --- |
|1|0014_trakt_review_counts.sql|Backfill review buckets, transaction triggers, ready-pick and planning indexes|
|2|0015_trakt_planning_cursor.sql|Nullable durable planning cursor; old page/checkpoint retained|
|3|0016_native_query_bounds.sql|Ordered latest-review/account and active-movie-watch indexes|

After checking the pending list contains exactly the expected files, Wrangler
applies them sequentially and records its ledger. Do not paste these migration
files into the console individually or manually edit the migration ledger.

```powershell
npx wrangler d1 migrations apply twildiary-v2 --remote --config wrangler.production.jsonc
```

Before publishing code, run `ios/deploy/postflight-d1.sql` read-only. Require all
17migration names, nine new schema objects, nullable TEXT `plan_after`, unchanged
existing review/checkpoint and incoming settings, and **zero mismatch rows**.
The bucket check deliberately covers only the active review, once. Reconcile any
legitimate concurrent change against its receipt rather than discarding it.
Failed/partial migration means stop, inspect the actual ledger/schema and
rehearse that exact export; do not drop tables or rerun raw SQL blindly.

Then deploy the frozen source's already-built main Worker:

```powershell
npx wrangler deploy --config wrangler.production.jsonc --keep-vars --message "native62 bounded Trakt review queries; D1 0014-0016 verified"
```

`--keep-vars` retains dashboard-managed Access/configuration variables. Existing
secrets stay server-side; never populate a plaintext secrets file, echo values or
change Access policy, routes, client IDs, Cron or callback URI for this rollout.
Capture the returned version and deployment timestamp privately. This document
does not authorize publishing an unqualified iOS candidate or starting native64.

## Verification and recovery

- First verify owner Access/native session and read-only workspace/review status.
  Unauthenticated traffic must still be denied. No public debug/health bypass.
- Confirm the same incomplete review/counts/choices remain. A status read must
  not apply/skip a proposal. Use the owner's already-approved import only when
  normal continuation is wanted; never invent a hosted watch just for testing.
- Observe actual D1 rows read/written for representative status and apply steps,
  not just query duration. Check there are no repeated whole-review COUNT scans
  or OFFSET planning scans. Record incremental costs and account UTC-day usage;
  rolling24h metrics are a different window. No fixed imports/day guarantee.
- Verify restart, navigation, cooldown and progress with a qualified phone build.
  Native63cold-quota Pause UI failed; native64repair is untested. Backend rollout
  cannot make that UI regression disappear.
- Incoming remains intentionally manual-review-paused until the owner finishes
  that review. Real matched-watch latency and active Free10msCPU remain open
  checks; the previously observed paused3ms does not prove them.

If the new main Worker misbehaves, revert **code** to the freshly recorded previous
Worker version using `wrangler rollback <previous-version-id> --config
wrangler.production.jsonc`. Leave additive schema, counts, review records and
acknowledgements intact. Old code remains schema-compatible but has the old query
cost, so avoid restarting a large bulk import while preparing a forward fix.
Do not automatically restore D1: a Time Travel restore overwrites subsequent
watches/settings/receipts. Database restore is a separate recovery decision with
write quiescence and reconciliation; preserve its undo bookmark if ever used.
Free-plan Time Travel retention is seven days. No paid upgrade is required by
this plan.

## Free-tier budget acceptance — still open for production

Owner explicitly requires this setup to remain on Free. All rehearsals above use
local disposable D1, so their hosted D1 rows read/written are both zero. The last
hosted check, before the26October reset, returned7500read quota; production is
**not** currently certified within budget. No paid upgrade or hosted stress run
is part of preparation.

Use these engineering targets after deployment, not the platform maximum as a
normal operating target:

| Resource | Platform allowance | Acceptance target |
| --- | --- | --- |
|D1 reads|5,000,000/account/UTC day|At most2,500,000/day projected **account total**, reserving50%headroom|
|D1 writes|100,000/account/UTC day|At most50,000/day projected account total, including index/trigger writes|
|Scheduled Worker CPU|10ms/invocation on Free|MeasuredP99under8ms for idle, refresh, matched and cold-metadata phases|

These targets are chosen headroom, not measured results or new runtime limiters.
The existing scheduler's5,000daily work units estimate import/metadata writes;
they are **not** a D1read meter, a global write cap or proof of these targets.
One minute means1,440ticks/day: even a cheap tick must be multiplied by1,440and
combined with phone refreshes, normal writes, bulk imports and other databases
in the account. Index creation/backfill also consumes quota. Native tests and
query plans do not measure any of those hosted costs.

Read current **UTC-day/account** metrics before the hosted verification phase;
do not subtract a rolling24h chart from today's allowance. Keep verification
small: at most five initial status refreshes, inspect row deltas before more,
and use only natural owner-approved imports for apply observations. Cap this
initial diagnostic phase at50,000additional measured reads (1%of daily Free),
then stop and investigate unexpected scans. Migration/export costs are separate
one-time deployment costs and must also fit the actual remaining account budget.
Do not assume a50,000budget prevents a single unexpectedly expensive query;
check plans and the restored real export first.

For each measured path record rowsRead/rowsWritten per request, expected daily
frequency, account totals/other traffic and separate rollout overhead. CPU needs
actual enabled phases; paused-only samples do not qualify. If the targets fail,
reduce proven excessive reads/polling or defer bulk work instead of raising the
budget or silently switching plans. Codemagic/GitHub minute allowances are
separate account quotas and are not certified by a D1measurement.

Official references checked26October2026:
[migrations](https://developers.cloudflare.com/d1/reference/migrations/),
[export behavior](https://developers.cloudflare.com/d1/best-practices/import-export-data/),
[Time Travel/restore](https://developers.cloudflare.com/d1/reference/time-travel/),
[D1 allowances and row/index metering](https://developers.cloudflare.com/d1/platform/pricing/),
[Workers limits](https://developers.cloudflare.com/workers/platform/limits/),
[Wrangler deployment flags](https://developers.cloudflare.com/workers/wrangler/commands/).
