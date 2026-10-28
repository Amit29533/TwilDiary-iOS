# D1 Free-tier assessment — 26 October 2026

## What Cloudflare actually reported

Read-only inspection of the existing dashboard's GraphQL responses; no additional
library change, deployment or native build. The only D1 database in the account
is in APAC with replication disabled. The region menu lists only APAC Primary.

| Scope | Rows read | Rows written |
| --- | ---: | ---: |
| Dashboard test selection, 10:08–10:17 IST | 28,977 | 54 |
| The three action minutes within that selection | 21,715 | 54 |
| Known operator verification SQL within the selection | 5,650 | 0 |
| UTC day through 10:30 IST, including rollout | 219,025 | 12,758 |
| Deployment five-minute bucket, 09:40–09:45 IST | 62,650 | 12,548 |
| Published Free allowance per account/UTC day | 5,000,000 | 100,000 |

These are captured **Row Metrics** (`d1AnalyticsAdaptiveGroups`) sums, not exact
per-POST meters. The test selector includes minute buckets 04:38–04:47 UTC. For
a strictly half-open 04:38–04:47 interval, remove the upper boundary's single
4-row scheduler read: 28,973 reads, still 54 writes. The three action minutes are
04:41, 04:43, 04:44 UTC; their separate costs are 7,252/20, 7,250/20, 7,213/14
reads/writes. They include UI/search refreshes and any concurrent requests.
Raw responses and request filters are retained privately under ignored
`.local/cloudflare-cost-20261026`; no cookies/auth headers were exported.

Cloudflare's SQL-insight summary (`d1QueriesAdaptiveGroups`) reports different
aggregates: test selection 34,724/50; current day 177,536/13,325. Filters were
checked: same database, APAC and time range. The reason for the difference is
not established; do not invent a conversion or claim both are precise invoices.
Use the Row Metrics dataset recommended by the pricing documentation for this
assessment, retain both observations and allow for analytics ingestion updates.
The earlier rounded dashboard-card 98k/13k statement is a historical snapshot,
not the current exact UTC-day usage or a measurement of these three changes.

## What can be concluded

Reported day usage is 4.38% of the read allowance and 12.76% of writes. Most observed
writes belong to the one-time deployment bucket. Removing that whole bucket
leaves 156,375 reads / 210 writes over the first five hours. If that particular traffic
mix continued at the same average rate, it would be about 750,600 reads / 1,008 writes
per day. That is a conditional arithmetic illustration, **not** a representative
full-day benchmark: it includes diagnostics and the sample, and excludes the
one-time bucket plus its concurrent ordinary traffic.

The manual individual-apply pattern averaged about 7,238 reads / 18 writes per action
minute, including refresh work. Naively repeating an unchanged pattern 2,000 times
would imply about 14.48 million reads / 36,000 writes. Reads would exceed Free. This
is not a native bulk prediction: proposal counts, library size, metadata misses,
retries and concurrent traffic change the cost as an import advances.

Source inspection confirms native `applyAllReady` refreshes the diary at the end,
not after every item; recovery uses an unfiltered review GET. Individual controls
do refresh after each change. The live sample used individual production review
controls with a text filter, which repeatedly scanned matching proposals and
reloaded workspace pages. SQL Insights identifies that filtered review search
and workspace watch/episode reads as major recurring patterns. The source behavior
also exists in native62. No runtime change was made in this assessment.

**Assessment:** current observed private use fits Free comfortably; a 2,000-change
native bulk run is not yet certified. To finish 2,000 changes with 50% of the daily
allowance reserved, average total attributable cost must stay below 1,250 reads
and 25 writes per change, with other account traffic also covered. Existing
bounded status/ready-pick samples are promising, but are not a complete apply path.
Measure a separately authorized, bounded native bulk sample before certifying
that capacity. Do not start another large import merely to obtain a benchmark.

The currently review-paused scheduler's observed lease query reads 4 rows/tick
and writes 0. At 1,440 ticks/day that path is about 5,760 reads/day. This describes the
paused path only; active incoming imports, metadata work and Free Worker CPU
remain separate unmeasured acceptance items. No paid upgrade is part of this work.

## Official limits and measurement references

- [D1 pricing, index/DDL metering and UTC reset](https://developers.cloudflare.com/d1/platform/pricing/)
- [D1 Row Metrics and SQL Insights datasets](https://developers.cloudflare.com/d1/observability/metrics-analytics/)
- [Workers pricing and separate resource limits](https://developers.cloudflare.com/workers/platform/pricing/)
