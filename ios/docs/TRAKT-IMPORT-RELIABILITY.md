# Bulk import reliability and D1 read budget

## Observed on 25 October 2026

Owner reported a roughly2,000-change review stopping without automatic recovery,
stopping when leaving Trakt, missing progress, and reaching a database limit after
roughly600imports. The opened Cloudflare D1 dashboard was inspected read-only.
Its **Last24hours** window showed12.23million rows read,36,560rows written,
34,980queries and12.35MBstorage. This rolling window is not the current UTC
quota day or all databases in the account.

The displayed query costs identify repeated review scans:

| Query | Calls | Rows read |
| --- | ---: | ---: |
| Choose next ready change, ordered, without SQL LIMIT |627|2.30M|
| Count pending links |1,668|2.62M|
| Count safe pending proposals |1,480|1.97M|
| Group all proposal states |1,202|2.11M|
| Order remote planning records with LIMIT/OFFSET |552|2.41M|

Calling Drizzle `.get()` did not put LIMIT1into the first SQL statement. Counting
an indexed range still reads that entire range. Therefore600imported records
can exhaust a read allowance even when write usage remains below its allowance.
Cloudflare's published free allowance is5million reads/100,000writes per
account/day, resetting00:00UTC (05:30India time). Indexes and aggregate triggers
also have write costs; an import count is not a database billing unit.

Sources: [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/),
[D1 analytics](https://developers.cloudflare.com/d1/observability/metrics-analytics/).

## Native58 candidate

- Store-owned approved bulk task survives leaving the Trakt view. A saved run ID
  permits the same approved review to resume after foreground/relaunch checks.
- User Pause revokes automatic continuation. iOS background suspension preserves
  that approval and stops requests; the app reconciles on return. This does not
  promise continuous background execution or an offline write queue.
- Removed the100request loop limit. Pacing is1second between successful bulk
  steps and0.5seconds during a scan. Server progress, conflicts and explicit
  Pause determine when to stop; two unchanged responses stop a stuck job.
- Typed network/provider errors retain Retry-After. A review GET reconciles each
  interrupted operation before further writes. Six consecutive failed recovery
  attempts stop with a resumable error. Account/snapshot conflicts require review.
- A D1 daily limit waits for its actual reset while the app remains open. Closing
  the app preserves the approved run; reopening checks that same review. No retry
  loop can bypass an exhausted daily allowance.
- Global applied/skipped/remaining counts and percentage, known-stage scan
  progress, cooldown details, Pause/Resume and rounded review actions.

## Additive backend candidate

Migration0014backfills at most40aggregate buckets per existing review. SQLite
triggers update those buckets in the change transaction. Status reads those
buckets rather than three full scans after every operation. The ready-pick
partial expression index matches the existing dependency order; the selection
now has an explicit LIMIT1. A partial ordered planning index removes repeated
sorting, although existing OFFSET checkpoints still incur skipped-row reads.

An explicit Trakt429rejection remains pending after cooldown only when no
uncertain-send flag is present. Lost/accepted-but-unconfirmed sends retain their
existing reconciliation guards. No blind watch POST replay was introduced.

Local SQLite regressions cover2,000changes,600applies/skips, retry/reclassification,
rollback, cascade cleanup, existing-review backfill and EXPLAIN QUERY PLAN for
both hot ordered queries. The full396Node tests pass. Native212test source and
17focused UI cases require the next macOS run; local grammar is not compilation.

## Rollout and evidence still required

**Not deployed; hosted migration not applied.** No hosted diary mutation or SQL
usage probe was run during this investigation. The daily allowance is exhausted.
Before rollout: complete candidate CI, preserve the existing production backup,
validate migration with Wrangler's local D1 runtime, then apply the additive
migration before deploying code that reads the aggregate table. Verify existing
review counts before resuming the owner's unfinished review. Inspect real D1
read/write metadata afterward; local EXPLAIN proves index selection, not hosted
metering or a numerical free-plan capacity guarantee.

Wrangler OAuth's direct analytics request returned401during the audit; the
authenticated dashboard supplied the evidence above. No credentials are stored
in this document, screenshots, fixtures or test logs.

## Current native/database audit follow-up

Native61passes219logic,17focused and10early UI cases; complete primary/extra-phone
acceptance is still being inspected. Its approved bulk worker supports progress,
app navigation, cooldown wait and read-back, including tested2,000changes.
A fresh process whose first status/review fails during quota still needs owned
bootstrap recovery; record this limitation separately from the passing warm
background-resume case.

0015replaces ongoing OFFSET planning with a durable ID seek, retaining old run/page
compatibility.0016bounds the other native first-row API reads and indexes review
recency/retirement plus latest active movie watch. Local migrations through0016,
query-plan regressions and407backend tests pass. All0014–0016hosted migrations and
real cost verification remain pending. These are additive indexes/counters/cursor,
not a library/history rewrite. Existing unfinished review must be preserved.

## Cold-process recovery candidate63

When status/review fails before the saved review is loaded, the retained import
controller now owns a bounded bootstrap task. The first request after a known
quota waits for its reset; provider throttles preserve Retry-After. Only GET status
and current review run during restoration. The exact approved run, connection and
session must still match before the paced apply worker receives control.
Explicit Pause clears approval and cancels restoration; background cancellation
preserves it for foreground read-back. Six failed recovery attempts or a fatal
account/auth/review change stop without writes. The UI shows known recovery state
and Pause rather than fabricating counts/percentage before the review is loaded.
Nine new native logic/URLProtocol tests and one isolated UI scenario are prepared;
local syntax/tool checks pass, macOS63runtime acceptance is still pending.

## Deployment preparation26October2026

[Backend rollout procedure](BACKEND-ROLLOUT.md) pins50134fc(native62)and records
actual localD1/export rehearsal through0016with2,000proposals and all original
rows preserved.27release-tool tests pass; hashed source/build payload retained
privately. No hostedmigration/deployment or new iOSbuild. Free-tier production
read-cost acceptance remains open; all prepDB tests consume0hostedrows. Native63
unit228pass but coldquotaPauseUIfailed; native62independentGHAfocusedUIalsofailed.
These UI failures are separate from its passing407backendcontract job.
