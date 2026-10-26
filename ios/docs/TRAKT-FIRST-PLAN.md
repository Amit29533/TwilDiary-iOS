# Trakt-first plan and gap verification — 26 October 2026

Status: design only. Ordinary watch mutations remain D1-first. This document
does not authorize a rollout, declare native64 compiled, or change hosted data.

## Verified current behavior

1. `src/routes/api/trakt/incoming/+server.ts` exposes GET status and PUT settings;
   neither invokes `tickIncoming`. `LiveIncomingTraktService` mirrors that API.
   `DiaryStore.refreshOnForeground` reads the D1 workspace. Its threshold is 10
   seconds. `resumeTraktOnForeground` resumes an already-approved manual transfer,
   not the incoming scheduler. App-open provider catch-up is new work.
2. Watch-event PATCH permits only revoke/restore and expectedVersion. Local
   restore clears revoked_at with concurrency guards. Incoming matching deliberately
   ignores an existing remote-history identity, including its revoked tombstone;
   nearby revoked candidates are held for review. These are correct protections,
   not an implemented remote restore protocol.
3. Query costs need an explicit independent gate. However, migrations 0014–0016
   were already deployed on 26 October: review counters/indexes, planning cursor
   and ordered latest-review/movie-watch indexes. See BACKEND-ROLLOUT.md and
   releases/backend62-production-rollout.json. Do not apply them twice or represent
   all index work as pending. A slower foreground threshold is still pending.
4. Editing an existing watch timestamp is out of scope. Selecting a date for a
   new watch exists; that is a different operation. The current official Trakt
   sync/history contract exposes GET, add and remove, not an in-place date edit.

The historical 11.8M reads figure supplied in the review is not independently
re-established by this verification. Preserve it as a reported incident, not a
newly measured figure. Latest captured account usage and measurement caveats:
D1-FREE-TIER-ASSESSMENT-2026-10-26.md.

## Authority and storage

- Trakt: linked movie/episode watched facts, rewatches and whole-number ratings.
- D1: confirmed read projection, operation journal and TwilDiary-specific fields;
  notes, tags, favorites, Dropped, files, manual titles, Trash, planned and Queue
  retain existing app semantics. Half-point overrides remain local.
- Device: protected offline snapshot and pending commands; credentials stay
  within the existing device/Worker boundary. Worker owns Trakt OAuth.
- Independent versioned backup: required. A serving mirror alone is not a backup.
  Existing D1 restore rehearsal does not prove a Trakt-history rebuild; R2 is not
  currently configured as a backup pipeline.

Trakt has notes, favorites and a dropped-show concept; retaining our versions is
a product/data-model decision, not evidence those provider features are absent.

## Stage 0 — cost stabilization before changing authority

- [x] Existing 0014–0016 migrations deployed and indexed representative queries
  inspected. Existing native-query-bounds tests guard latest-review/movie-watch
  plans and active-review lease lookup against full-history sorts/scans.
- [ ] Change automatic foreground snapshot refresh from 10 to an initial 60-second
  minimum, measured from successful data freshness where possible. Coalesce
  simultaneous scene activations. Explicit user refresh and mutation receipts
  must still refresh promptly; cooldown/quota guards remain authoritative.
- [ ] Prefer a cheap version/change check to repeated complete workspace reads;
  unchanged data must not trigger a full paginated snapshot. Measure the check
  itself; do not introduce an expensive aggregate fingerprint.
- [ ] Benchmark full native refresh, individual apply, bulk apply and idle/due
  scheduler paths using representative large disposable data. Attribute queries
  with EXPLAIN and D1 metadata, then compare small controlled hosted windows.
- [ ] Record rows read/written, request counts, dataset size, duration and projected
  daily frequency for every later stage. Include migration/index write overhead.
  Use Metrics > Row Metrics for quota totals and Query Insights for attribution;
  do not equate different analytics datasets or sum overlapping windows.
- [ ] Require a measured workload envelope below 5M reads/100k writes per UTC day
  with explicit headroom. The 2k-change native bulk and active Cron CPU remain
  unqualified. Stop expansion when measurements exceed the envelope.

## Stage 1 — baseline, durable commands and recovery

Preserve the existing review and backup before migration. Finish/cancel a review
only through its normal user action. Establish explicit Trakt/local identity
links; do not declare all same-title watches duplicates.

Persist an idempotent command before provider writes. Track desired local state,
operation generation, provider attempt, acknowledgement and reconciliation.
Serialize related commands. An uncertain POST must be reconciled before retry,
Undo or restore can send another conflicting operation. Account replacement,
disconnect and demo-data fences apply at execution and commit time.

## Stage 2 — watch, Undo and restore as one feature

Show optimistic state while pending, then publish a confirmed D1 projection.
Cancel unsent adds when possible. After a confirmed add, Undo removes only the
specific Trakt history ID, never every play of that episode/movie.

Explicit restore after confirmed removal is a new provider add and must reconcile
its replacement history identity. Retain the old remote ID as a tombstone, and
track the new ID against the logical watch and its new operation generation.
Do not clear all tombstones or let ordinary incoming sync revive a revoked play.
The incoming reconciler must recognize a pending explicit restore, so an echo
cannot create an extra local play or be mistaken for unsolicited resurrection.
Logical watch/version, current remote identity and historical removed identities
must be representable separately; exact schema is implementation work.

Required tests: add/Undo/restore; repeated restore; lost add/remove responses;
restart between each phase; incoming echo before/after confirmation; old-ID replay;
two distinct rewatches; stale Undo; account switch; manual-review overlap. Old ID
stays suppressed, one replacement active play remains, unrelated watches survive.
Existing tombstone tests do not certify this new state machine.

## Stage 3 — bounded incoming catch-up and foreground integration

Add an authenticated POST catch-up request (not a side-effecting status GET).
Reuse the scheduler's durable lease, account/generation fences, due/backoff times,
manual-review exclusion and D1 work limits. Coalesce app-open and Cron requests.
An active building/review/applying run returns paused; it is never bypassed.

Perform only bounded work or acknowledge a queued operation with observable
status; do not claim all backlog completed after one tick. The existing tick is
bounded to one history page and one watch. Cron remains a recovery path if a
foreground request is interrupted. Refresh D1 after confirmed revision changes.

Standard API budget is currently 500 reads/5 minutes and 1 write/second. Honor
provider rate headers and Retry-After; missing headers require bounded backoff
with jitter. Shared user activity means a local counter cannot promise the
provider's entire remaining allowance. Foreground requests cannot reset cooldowns.

Tests: simultaneous Cron/app opens; disabled/not-due/cooldown paths; active manual
review; lost trigger response; partial pagination; no-change result; disconnect
mid-response; delayed projection; duplicate triggers; quota reset recovery.

## Stage 4 — ratings and incremental reconciliation

Handle whole-number Trakt ratings and local decimal overrides explicitly. Resolve
provider additions/removals and simultaneous local operations incrementally,
preserving local extras. Bounded delta handling should reduce full reviews but
does not eliminate ambiguous matches, conflicts or uncertain provider writes.

## Stage 5 — qualification and controlled rollout

Pass local database/provider-failure tests and same-source native CI; inspect
phone evidence for optimism, offline recovery and Undo. Execute bounded live
samples only within the established workload envelope. Test independent backup
restoration including replacement Trakt IDs. Document actual limitations before
promoting an unreleased candidate. No Free-tier guarantee from three live changes.

## Verification performed for this revision

Command: `node --test tests/unit/native-query-bounds.test.ts
tests/unit/trakt-incoming.test.ts tests/unit/trakt-sync.test.ts
tests/unit/database.test.ts` (one line).

Result: **73 passed, 0 failed/skipped** against local disposable SQLite and fake
provider transports. No new native compile, deployment or hosted write. These
test existing behavior; future catch-up/remote-restore coverage remains pending.

Primary sources:
- https://developer.trakt.tv/docs/rate-limiting
- https://raw.githubusercontent.com/trakt/trakt-api/master/projects/api/src/contracts/sync/index.ts
- https://developers.cloudflare.com/d1/platform/pricing/
