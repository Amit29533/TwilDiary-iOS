# Incoming Trakt watches on Free

Initial rollout and the hardening below deployed 2026-10-25 from server source `66d625e`; the owner enabled incoming in iOS. A preserved active manual review currently pauses it. Current scheduled Worker version: `3150a352-0013-4151-a93a-00d6266b9b46`; main Worker: `1dc0eced-83ac-4312-8d40-73aa6124cba5`. No new migration was needed for the hardening.
This is the owner's requested extension of the earlier manual-only contract.
Connecting Trakt still enables nothing automatically.

## Flow

Trakt → minute activity check → bounded incoming history import → existing D1 →
existing diary API when iOS opens/resumes. The upstream playback application is
outside this implementation; it only consumes Trakt's recorded history. This is
completed-watch sync, not live playback position. Ratings, watchlists, conflicts,
deletions and old bulk history retain the reviewed two-way sync.

One invocation fetches at most one ten-item history page and processes at most one
viewing or public metadata phase. Movie/episode activity timestamps are checked
each minute. Unchanged activity avoids history requests, except an hourly overlap
rescan. New activity interrupts older pagination; recent watches take priority
over old backlog. An unfamiliar title needs a title-metadata tick, then a selected
season tick for series, then its viewing. Mapped watches normally need the next
successful tick; cold metadata can need two additional ticks. Trakt availability,
scheduling, provider errors, quota and backlog prevent a hard 60-second SLA.

History uses a fixed seven-day overlapping window and durable remote IDs. A new
backdated play would be missed by a naive `watched_at > last_check` cursor. Run
reviewed sync once for existing history, and for bulk imports older than seven
days. Concurrent changes restart from the newest page. Partial/inconsistent pagination and duplicate usable IDs fail closed without advancing. An individually malformed row with a valid history ID is quarantined as review/invalid_item with no retained payload and a never-due retry time; rows without usable IDs are skipped. Valid neighbours still advance/import. A scan is limited to 200 pages/2,000 recent plays;
larger batches need manual sync.

## Safeguards

- Default off. Owner-authenticated `GET/PUT /api/trakt/incoming` reads/configures it.
  No public trigger, Access bypass, bundled bearer or new service token.
- Small `workers/trakt-incoming` entry shares the existing D1/encrypted OAuth
  connection and refresh lease; it does not load Svelte SSR or copy the diary.
- Durable 50-second invocation lease. Every metadata/enqueue/watch write checks
  enabled generation, account/client, current connection version and absence of
  an active manual build/review/apply. Disable/disconnect fence late callbacks.
- Atomic viewing/status/acknowledgement batches. Unique operation/remote IDs and
  retained acknowledgements survive Undo/purge. Revoked plays are never revived.
- Trash/demo excluded; notes, score, favorites, Queue and Dropped status preserved.
  A single unlinked active local viewing within six hours links automatically (owner-selected Option B), preserving its local timestamp, origin and watch count. Multiple matches, conflicting previous baselines, undated matches and exact-minute revoked tombstones remain for review; no revival or fuzzy title matching. Link, canonical baseline and acknowledgement commit atomically with generation/account/title/event-version and single-candidate rechecks.
  Unmatched IDs/oversized metadata remain in review; no fuzzy name matching.
- Metadata only inserts missing records. At most 200 season summaries or selected
  episodes, 100 KB normalized season payload. Larger metadata uses manual sync.
- Conservative daily 5,000-unit record/metadata write budget, including estimated
  index amplification. Fixed lease/checkpoint overhead is separate. Failed
  attempts can conservatively consume units. Reset at midnight UTC.
- Trakt responses capped at 32 KB here, TMDB at 100 KB; manual clients retain
  their 2 MB cap. Honor Retry-After, otherwise exponential backoff up to an hour
  with positive jitter for rate limits that omit a valid Retry-After header.
  D1 quota backoff persists until UTC reset if D1 still permits that write. If
  exhausted D1 refuses it too, later ticks can only fail safely and retry.
- Enumerated log outcomes only; no raw exceptions, SQL/parameters, provider
  bodies, account IDs or credentials. Status exposes health/counts, not payloads.
- iOS foreground reads coalesce rapid scene changes and wait for pending writes.
  No phone background timer or requirement to leave the app running.

## Free limits and remaining measurements

Official limits checked 2026-10-25:

| Resource        | Free allowance                                         | Design                                                             |
| --------------- | ------------------------------------------------------ | ------------------------------------------------------------------ |
| Cron            | Every minute supported                                 | 1,440 invocations/day                                              |
| CPU             | **10 ms per Cron invocation**                          | Small bounded phase; production CPU not yet proven                 |
| Worker requests | 100,000/day, account shared                            | Minute checks plus normal app traffic                              |
| D1              | 5m rows read / 100k rows written daily, account shared | Indexed singleton/provider/episode/due-job lookups; bounded writes |
| Subrequests     | 50/invocation                                          | Ten-item enqueue + one viewing/metadata phase                      |

SQLite correctness/query plans and a Wrangler dry run do **not** prove the 10 ms
CPU budget. The initial hosted samples measured3ms while fenced by the active manual review; that proves only that paused path. Still measure a day of normal enabled/unchanged activity samples, OAuth refresh, matched-title watch, cold movie and cold season via Cloudflare metrics/tail, plus actual D1 rows including indexes. Use8msP99 as engineering headroom below the10ms limit; it is not a platform guarantee.
Other account traffic shares the allowance. If cold metadata exceeds Free CPU,
leave those entries for manual metadata while retaining the cheap matched-watch
minute path. Never silently switch to paid; 15-minute wall time is not CPU time.

Sources: [Workers limits](https://developers.cloudflare.com/workers/platform/limits/),
[D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/),
[Cron configuration](https://developers.cloudflare.com/workers/configuration/cron-triggers/),
[Trakt activity/history contract](https://github.com/trakt/trakt-api/blob/master/projects/api/src/contracts/sync/index.ts),
[current Trakt rate-limit guide](https://github.com/trakt/trakt-api/blob/master/projects/developer/src/lib/guides/rate-limiting.md).

## Source and validation

`src/lib/server/trakt-incoming.ts`, owner API route, worker entry/config and
generated `0013_trakt_incoming.sql`/Drizzle schema/snapshot/journal. Migration adds
three tables, one due-job index and a provider-tombstone trigger on title purge;
existing diary tables are not rewritten. Manually re-adding a title explicitly
allows future incoming watches again; a missing purged title is never auto-added.
Config has an all-zero local DB ID. No deployment workflow/signing/credentials.
`tests/unit/trakt-incoming.test.ts` uses disposable SQLite and mocked Trakt/TMDB.
Native service/panel/foreground tests belong to the next iOS validation batch.

```powershell
node --test tests/unit/trakt-incoming.test.ts
npm test
npm run check
npx tsc -p workers/trakt-incoming/tsconfig.json
npx wrangler deploy --dry-run --config workers/trakt-incoming/wrangler.jsonc
```

## Rollout and rollback

1. Verify actual database/binding and pending migrations; take a recoverable
   backup and apply only the reviewed additive migration to existing D1.
2. Release the incoming API with the existing Worker, retaining Access, owner and
   same-origin write checks. Existing web deployment workflows are unchanged.
3. Configure the small scheduled Worker with that same D1 and existing client ID,
   server encryption key and TMDB read token through Cloudflare secrets. No public
   route. Do not commit/print secrets or put them in CI artifacts.
4. Keep opt-in off initially; validate runtime/CPU with an isolated account. Then
   enable in iOS and check one completed play, a cold season, duplicates,
   disconnect/disable and local Undo on a phone.
5. To roll back, disable incoming first/remove its Cron. Keep acknowledgements to
   prevent replay. Existing manual sync and diary data remain available.

The owner approved rollout on2026-10-25 and completed Wrangler reauthorization.
Migration0013 is applied, no migration is required for this hardening. Scheduled
Worker version093945a6-e9b8-4520-a402-313514742063 and main Worker
versionb6bf0ab8-adf5-4ebc-a08d-09980fc207ce are the initial deployed baseline;
PROGRESS.md records subsequent versions. The earlier403 was resolved. Existing
Access/owner checks and secrets remain in place. The owner confirmed the incoming
setting survives app restarts. No end-to-end latency or active-import CPU claim
follows from that setting check or the idle logs.

## Manual review, health and local-watch linking

Any manual run in building/review/applying still fences incoming reads and writes.
Do not narrow this to building/applying: parked reviews include Skip choices and
proposal identities which must not be bypassed. To resume incoming, the owner can
apply ready changes, resolve/skip conflicts, then cancel what remains; already
applied baselines are kept. Or stop the scan without applying. The scheduler never
cancels the owner's run. A pause over seven days may leave older plays outside the
automatic overlap; catch these with a manual scan.

GET status adds pausedBy (building/review/applying/null) and overdue. Overdue means
enabled, not manual-paused, and next_at more than ten minutes overdue. Future
provider/quota backoffs and disabled states do not trigger it. This detects missing
progress, not the cause: check Worker metrics for exceededCpu/errors. Off then on
invalidates the old lease and resets failure scheduling. iOS decodes both fields
optionally for older backends, explains the phase/seven-day window and prioritizes
overdue health over stale stored errors.

The six-hour rule shares one SQL predicate between candidate lookup and the final
import fence. Exact-minute matches include intentional revoked tombstones; the
wider window includes only non-revoked plays. A sole dated, unlinked local match
gets remote_history_id plus a version increment. Its original date/origin/count
and title fields remain unchanged. The baseline stores the local and remote dates
as they stand, under the exact existing SHA-256(account:history:local-key) scheme;
a later manual comparison proposes no history change for this pair. A failed
batch rolls everything back, and any concurrent extra candidate/manual run/edit/
disable makes the conditional link fail safely. Existing links are not reassigned.
Genuine nearby rewatches can need review. The manual engine's push reconciliation
still uses exact-minute matching; broadening that is explicitly outside this pass.

No new migration, index, provider credential or player integration. Existing
watch/title-progress, baseline-local and remote-history indexes support lookups.
The conservative matched-episode test stays below50 prepared statements; D1
counts a batch as one query against the invocation cap, while row/index writes
still consume daily account allowance. This is not a CPU measurement.

Validation before hardening deployment:38 incoming tests and391 complete Node tests
pass on disposable SQLite/providers. Svelte/TypeScript, worker tsc, production
build and dry-run results are recorded at the final PROGRESS.md checkpoint. Three
new Swift health/decode tests passed within native46's173-unit Codemagic run;
the full native UI acceptance still failed separately. No claim that Windows
compiled or ran Swift. A fresh SQL export failed at its endpoint before rollout;
the fresh official D1 Time Travel bookmark and earlier verified private SQL
backup are recorded in PROGRESS.md. No restore was performed.
