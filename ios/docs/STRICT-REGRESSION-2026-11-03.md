# Strict regression evidence — 3 November 2026

Branch `codex/arena-ui-integration`; current native UI parent `b52f3e0`, Arena PR12 parent `53daceb`. Latest checkpoint `3eab289` plus working-tree repairs: the SHA alone is not the complete tested source.

**Local checks pass; native acceptance and production deployment remain unverified. The reviewed candidate is ready for native test execution.** Real accounts were read-only. All mutations used isolated databases or fixture transports. This is bounded testing, not exhaustive execution of every state or every line.

Raw logs/JSON/screenshots: sibling workspace folder `outputs/regression-2026-11-03/`. Harnesses: `tests/benchmarks/`. The HTTP writer hard-codes loopback and cannot target production.

## Test results

| Check | Result | Evidence file |
| --- | --- | --- |
| Complete backend/domain/client/database suite | **580/580**, 37,435.3 ms | `full-unit-final.log` |
| Svelte/TypeScript/service-worker type checks | **0 errors, 0 warnings** | `static-final.log` |
| Production web build | **Passed** | `build-final.log` |
| Auth subset | **17/17**, 2,839.4 ms | `auth-final.log` |
| Provider/vault/delivery subset | **43/43**, 3,628.2 ms | `providers-final.log` |
| People/rating/UI wiring contracts | **25/25**, 4,556.0 ms | `ui-contracts-final.log` |
| Jellyfin library/locations/scanner subset | **13/13**, 1,242.2 ms | `jellyfin-scanner-final.log` |
| Compiled Worker + isolated local D1 | **14/14 HTTP scenarios**, including maximum archive | `worker-http-final.json` |
| Built service-worker runtime | **3/3**, 264.9 ms on final rebuilt output | `pwa-final.log` |
| Python release/helper tests | **29/29**, 6.272 s | `python-helpers.log` |
| Swift parser comparison | **213 files**, no new parse errors; not semantic compilation | `swift-parser-final.log` |
| Production dependency audit | **0 vulnerabilities** | `npm-audit-production.json` |
| Full toolchain audit | **4 low entries** from one unpatched build-tool advisory; no moderate/high/critical | `npm-audit-all.json` |

Subsets overlap the complete suite; do not add their counts. UI contracts are source/data assertions, not native rendered geometry. One build attempt hit a Windows directory lock from the local watcher (`build-final-windows-lock.log`); stopping it allowed the build to pass.
The final changed provider/UI contract rerun also passed **55/55** (`last-changed-contracts.log`), overlapping the full suite. Two request-boundary tests verify byte-counting, cancellation of an oversized stream without a length header, ordinary versus archive limits and rejection of malformed UTF-8.

## Benchmarks

Windows 10, Intel i5-8350U, 8 logical CPUs, about 16 GiB RAM, Node 24.21.0, SQLite 3.53.4. Real Drizzle/in-process SQLite, three warmups, 20–30 samples/query. No WAN latency, hosted Cloudflare CPU or device rendering is included. Primary evidence **`benchmarks-uncontended.json`** was rerun separately; `benchmarks-final.json` overlapped other tests and is retained only as a loaded-host sample.

| 3,000 titles / 24,000 episodes / 60,000 watches | Median ms | p95 ms | SQL/op |
| --- | ---: | ---: | ---: |
| Home | 5.429 | 5.816 | 27 |
| History first page | 0.756 | 1.272 | 1 |
| Statistics | 193.699 | 221.378 | 2 |
| Workspace titles page | 2.690 | 3.105 | 4 |
| One-title refresh | 1.566 | 2.307 | 7 |
| Unchanged delta | 0.074 | 0.097 | 1 |

| Operation | Samples | Median ms | p95 ms |
| --- | ---: | ---: | ---: |
| Signed session verification | 500 | 0.217 | 0.366 |
| Vault encrypt + CAS + decrypt | 100 | 1.922 | 2.661 |
| Maximum 5,000-row CSV parse | 10 | 17.656 | 35.186 |
| Repeat archive import, 300 titles | 10 | 99.296 | 157.704 |

Archive repetition uses 901 statements / two round trips: ownership preflight plus atomic write batch. Raw JSON includes every sample, p99, process CPU, RSS/heap deltas, result sizes and query plans; these are not peak device-memory measurements.

Before index `0025`, large-diary History median was **243.718 ms**, p95 **501.448 ms** (`benchmarks-before-history-index.json`). Final median is about **322 times lower** in separate local runs, not a guaranteed production speedup. Statistics remains the slowest measured large-diary query and still scans aggregates.

## Torture and conflict report

- **400 optimistic attempts:** 50 rounds × 8 writers, **50 accepted / 350 conflicts / 0 lost updates**. Asynchronous interleaving against one SQLite fixture, not distributed production load.
- **Worker title race:** 12 same-version requests → **1 success / 11 HTTP 409**.
- **Worker vault race:** 6 same-revision requests → **1 success / 5 HTTP 409**.
- **CSV:** 500 deterministic malformed inputs parsed or failed validation; 1,000 Unicode/quoted/multiline records preserved; 5,000-row maximum parsed. Row/column/field explosions rejected.
- **Maximum compiled-Worker import:** 5,000-title archive accepted and first/last title read back in **2,086.3 ms** total locally. The archive route now rejects oversized streamed UTF-8 bodies before buffering the full request. This does not certify production CPU/billing limits.
- **Atomicity:** injected late archive and tag-storage failures leave no partial write. Cross-title/provider/episode/watch ownership conflicts reject. Repeat import preserves operation identities and version semantics.
- **Delivery:** fixture HTTP 401/403/429/503, empty/malformed/HTML receipts, missing mappings, changed credentials, quota denial, lost history replies and concurrent flushes. Confirmed checkpoints persist; uncertain history is not blindly replayed.
- **Vault:** explicit clears, omitted fields, stale revisions, old servers, corrupt pending paths, storage denial, mismatched client/token pairs and edits during conflict review retain expected settings.

## Per-service results

| Service | Verified evidence | Limit |
| --- | --- | --- |
| TwilDiary / Cloudflare | Local Worker **14/14**. Production aggregate SELECT: **308 titles, 3,174 episodes, 3,464 watch rows; 6.3815 ms SQL, 6,947 rows read, 0 written**, SIN/APAC. Four anonymous routes: **Access 302 + no-store**. | No production write/load/deploy/migration. Local workerd does not certify hosted CPU limits. |
| Trakt | Fixtures cover immutable OAuth owner/PKCE/state, refresh lease, reconciliation, cancellation/throttle, bounded 2,000-play import and durable receipt retries. | Live settings/activities/history all **HTTP 403** at external edge. Live auth/sync acceptance unverified; no refresh/write. |
| Simkl | Fixtures: full episode dates, null new-account activity, unknown dates/envelopes, rating scale/removal, planning/dropped and durable receipts. | Not connected; fixture-only. Unsupported plan removal stays pending. |
| WeTrakr | Fixtures: compact snapshots, decimal ratings, favourites/planning/dropped, unknown dates and storage failures. | Not connected. Full unpaginated 1,000-row pages reject. Detailed docs returned 403; unverified removals blocked. |
| MDBList | Fixtures: community ratings, read-only connection test and watchlist payload/receipts. False zero-row import success removed. | Not connected. History/rating delivery unsupported/pending; live contract not certified. |
| TMDB | Metadata/people/cast/episode-rating fixtures; **four HTTP 200** real person searches, **144.860–584.129 ms**. | Searches do not certify native UI routes. |
| AniList | Five public profiles: Saori, Rina, Asami, Kurumi, Sakuta. **HTTP 200, 372.934 ms**; bios 330–2,423 characters, links/aliases/missing fields. | Data shapes/fixtures verified; native rendering pending. |
| Jellyfin / scanner | **13/13** fixture library/location/scanner checks, including rollback and owner protection. | No live credential/session in selected server configuration; device connection unverified. |

Sources: `live-readonly.json`, `cloudflare-readonly-counts.json` and service test logs. Fixture passes are not live two-way-sync passes. Some removals/favourites/status operations intentionally remain review-only. [D1 batch semantics](https://developers.cloudflare.com/d1/worker-api/d1-database/), [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) and [official Simkl schema](https://api.simkl.org/openapi.json) informed repairs.

## Auth, UI wiring and animations

Auth tests cover owner-bound Access/session channels, expiry/rotation/tampering, immutable Trakt identity, one-use PKCE state, refresh leases and persisted address/global throttling. Local Worker checks additionally verify HttpOnly/SameSite cookie sign-in, anonymous API rejection and cross-origin write rejection. `/sign-in` is data-free; return paths stay internal. Synthetic browser passcode sign-in succeeded. Repaired sign-in is not deployed; native locked/denied Keychain tests need Xcode.

Browser checks at **390 × 844**: sign-in → empty Home → seeded Home → Library grid/list → title → Notes save/reload → Library → More → provider settings. Notes and collection tag persisted. Empty startup no longer imports demos. Title/Notes at **320, 390, 430, 1,024 px** showed no page-wide horizontal overflow (`web-responsive.json`). This is limited route coverage, not all-screen overlap certification.

Screenshots: `web-empty-home-fixed.png`, `web-notes-saved.png`, `web-library-list.png`. These are **web**, not native redesign proof. Native source review retains shared Home/History grid geometry, inline dates, source-free compact ratings, full-width long-location facts, neutral biography links, accent hearts and native source routes. Corresponding native geometry/accessibility tests have no current-candidate runtime pass yet.

**No native FPS, dropped-frame/hitch ratio, launch-time or animation score is available.** Prepared XCTest metrics use five launch and five scroll CPU/memory/clock/signpost iterations. Physical-device smoothness, background wake/expiry, locked Keychain, battery and Live Activity presentation remain unmeasured. Backend timings are not animation results.

## Native attempts and gate

| Build | Checkpoint | Actual result |
| --- | --- | --- |
| `6ae92fdae83a9019991c83da` | `77bac45` | Core compile failed: incorrect Trakt activity member; fixed in `4b649dc` |
| `6ae930f7e83a9019991c8416` | `4b649dc` | Core test compile failed: incomplete schedule fixtures; fixed in `3eab289` |
| `6ae97717e83a9019991c9502` | `2c6c74a` | Core compiled; **112/114 passed**. Two fixture assumptions failed: unmapped sample title and a remote rating without a shared baseline. Corrected with explicit mapped data and assertions for both unreviewed preservation and baseline-approved decimal import. |

No attempt yet reached full app runtime UI/performance tests. The next integration run must compile final repairs, execute Core/app/UI suites, inspect screenshots/metrics and verify unsigned packaging with Widget extension. It now also invokes the existing compact/large-phone layout runner with profile formatting and large-text personal-profile cases, preserving those result bundles/screenshots. Its result will be recorded after execution. The old successful current-UI build is not substituted as evidence.

No merge, production deployment/migration or real-account mutation is represented by local passes. Production dependency audit is clear; full toolchain retains one unpatched low [deepmerge advisory](https://github.com/advisories/GHSA-gcqx-w48m-w2h4), surfaced as four entries. npm's obsolete framework downgrade was not applied.
