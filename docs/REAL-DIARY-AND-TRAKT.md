# Real diary dashboards and Trakt — 22 October 2026

This increment connects the polished Home, Glance, Stats/history and Locations screens to the owner's D1 library. It also implements the Trakt connection, personal recommendation feed and reviewed two-way sync. Trakt has not been connected to a real account yet. No commit, push, cloud provisioning or deployment was performed; the old Netlify project was not used.

## Real-library screens

- `/diary/home`: current watching carousel, five-second rotation/manual scrolling, quick episode updates, tinted recent-history artwork, Planned titles, and horizontal Explore/Queue/Disk Map/Locations/Fix mismatches shortcuts.
- `/diary/glance`: bounded pages of Watching titles, Shows/Anime/search/on-PC filters, selected seasons, distinct watched-episode counts, next aired episode, exact viewing Undo, favorites and independent Queue. Unloaded seasons open the title's lazy metadata loader rather than accidentally recording a movie watch. Next-episode selection works beyond the first 50 stored episodes.
- `/diary/activity`: actual viewing and title totals, unknown-date accounting, circular interactive genre chart, titles/viewings measures, genre percentages and library links, and paged artwork history with title/date filters.
- `/diary/files`: paged mappings, present/disconnected/missing evidence, paths and a copy action. This displays existing mappings; it does not claim that scanner upload/pairing has been built.
- The real workspace now uses Home/Library/Glance/Stats/More navigation. Title pages activate Glance. Explore remains separate from Library. The welcome link opens Glance.

The sample `/preview` remains separate. No sample library was seeded into the owner's D1. The owner's Wednesday entry and watch history were not changed for testing.

## Daily-use reliability and UI fixes

- Home and Glance can display a bounded session-memory cache while refreshing. Cached totals expire after five minutes and invalidate after confirmed writes from any real-diary screen, including existing Library/title actions. Private diary data is not persisted into a new browser cache by this increment.
- Progress writes retain their operation IDs after an uncertain response. Overlapping taps cannot create two writes. Undo targets the exact saved viewing and version; a failed edit cannot retain an unrelated previous Undo.
- Season selection survives favorites/Queue updates. Stale season requests are aborted and cannot overwrite a newer choice.
- Stats filter changes reuse valid totals rather than refetching the entire aggregate each time. History cursors are stable, scoped to filters and Unicode safe.
- Fixed carousel cards overflowing their slide and clipping the episode button on phones. Narrow-phone titles use the full available text width below the action icons. Added contrast shadows to artwork actions and removed the unwanted SVG chart focus rectangle while preserving keyboard feedback.

## Trakt behavior

Confirmed scope: **watched history, title ratings, and watchlist ↔ Planned**. Queue is an independent download reminder. Notes, file paths, drive mappings, favorites, Queue and scanner state are not exported.

`More → Trakt` provides app setup, account connection/disconnection, explicit decimal-rating choices, Preview sync, resumable steps, a cooldown timer, safe additions and per-conflict Keep TwilDiary / Use Trakt / Skip controls. Removals and simultaneous differences always require review. Nothing syncs merely because an account was connected. Sync is manually initiated in this increment; no background polling or scheduled account writes are enabled.

The owner subsequently requested opt-in minute incoming watches on 2026-10-25. The additive implementation and Free-plan constraints are documented in [TRAKT-INCOMING-SYNC.md](TRAKT-INCOMING-SYNC.md). It remains undeployed/disabled; the earlier reviewed two-way/deletion rules still apply.

- PKCE sign-in uses a random owner-bound state, encrypted verifier, one-use callback and HTTPS redirect on the app's own origin. No client secret is required. Installed-PWA users are directed to complete sign-in in the browser so Safari and standalone storage do not split the state cookie.
- Access and refresh tokens are AES-256-GCM encrypted in D1 using a server-only key. Refresh uses a database lease and version check for rotating refresh tokens. Disconnect clears local token material and preserves the diary/baselines.
- A preview collects all explicitly paginated provider pages before proposing changes. Missing pagination, invalid items, inconsistent totals or changed remote activities block application rather than being interpreted as removals.
- Plans, progress and baselines persist in D1. Concurrent starts share one active run; concurrent application is leased. Existing matched items link in bounded batches. Baselines retain reviewed differences so a deliberate choice does not immediately bounce back on the next sync.
- A watch is removed using its exact Trakt history ID, never a broad title/season deletion. Remote removal revokes the local event rather than purging it. Trakt watchlist removal does not trash a title or invent a replacement watch status. An incoming watchlist item cannot silently turn an existing Watching title into Planned.
- Before exporting a new viewing, sync looks for its exact provider episode/movie and matching play. A durable unconfirmed-send marker is written before the POST. After a lost response, recovery only checks Trakt; it cannot blindly resend. This guard survives Skip and a new preview. Successful reconciliation requires a fresh preview for remaining changes.
- The owner confirmed rounding for Trakt while preserving local decimals (for example, 9.5 → 10 on Trakt, with 9.5 retained in TwilDiary). The sync panel defaults to that rule; whole-number-only sync remains available.
- Personal recommendations in Explore use the connected account's refreshed token and bounded TMDB enrichment. There is no community-feed fallback presented as personal recommendations.
- Temporary completed/cancelled snapshots older than seven days can retire one at a time when a new preview starts. Baselines, real watches, active review work and all unconfirmed-send guards are preserved.

This is a reviewed, resumable sync, not a transaction across two independent services. Another Trakt client can still edit data between a remote activity check and a write. Live provider behavior and real-account authorization remain to be verified after connection.

## Connect your account later

1. Finish the fresh Cloudflare hostname, D1 and Access setup. The private app must be reachable over HTTPS.
2. Create a [Trakt API application](https://app.trakt.tv/oauth/applications/new). Register the exact redirect URI `https://YOUR-NEW-HOSTNAME/api/trakt/callback`; the live setup panel displays it. Follow Trakt's current application registration requirements.
3. Enter the Client ID in the local masked More panel if preparing locally. This saves only to ignored `.dev.vars` and creates a 32-byte encryption key if absent. It does not connect or validate the account. Production uses Worker secret configuration, not the PC-only form. Preserve `TRAKT_TOKEN_KEY` securely when moving the encrypted D1 connection.
4. Connect Trakt on the new HTTPS app. Choose the decimal-rating rule, preview, review differences/removals and apply the desired changes.

Official guidance: [OAuth](https://developer.trakt.tv/docs/authentication-oauth), [PKCE](https://developer.trakt.tv/docs/pkce), [creating an app](https://developer.trakt.tv/docs/create-an-app). Do not paste credentials into chat.

## Verification

- `npm run verify`: **179 unit/domain/database/API/controller tests and 3 compiled service-worker tests**, zero Svelte/TypeScript errors or warnings, successful Cloudflare production build. Log: `verification-real-diary-trakt.log`.
- New cases exercise real dashboard counts, spoilers, large seasons, Unicode history cursors, local-day filters, Trash/revoked events, multi-genre totals, PC filters, encrypted OAuth, refresh rotation, owner guards, concurrent configuration saves, merge baselines, exact removals, unknown-date rewatches, lost responses, concurrent runs/writes, rating conflicts, Queue preservation, missing provider identities, rate-limit cooldowns and snapshot retention.
- Browser QA checked the owner's real read-only Home/Glance/Stats/More and the masked setup form. A separate loopback-only server used in-memory SQLite and public TMDB artwork to exercise populated real components, +1/Undo, season changes, favorite updates, automatic carousel movement, narrow-phone wrapping, chart interaction and tinted history. API writes on that fixture never reach the owner's development server. Reproduce with `node tests/helpers/owner-ui-server.ts` after starting the PC-only TMDB-enabled dev server; it binds only `127.0.0.1:5192` and loses its fixture changes when stopped.
- Phone layouts were inspected at 320px and 393px, plus desktop. This is Chromium viewport evidence, not physical iPhone/Safari certification.
- The built production Worker with fixture Access configuration and `LOCAL_DIARY=1` returned **401 + no-store** for real pages, APIs, Trakt routes, the development setup path and preview. Spoofing the owner-email header did not grant access.
- A local Wrangler **dry run**, without uploading/deploying, produced the final Worker bundle. It and built client assets were scanned privately: **zero configured credential matches**, no development-owner identity and no Node TMDB transport/local setup middleware in the final Worker. Result: `verification-worker-private.json`. No credentials are contained in these reports.
- Screenshots: `screenshots/real-home-fixture-phone.png`, `screenshots/real-glance-fixture-phone.png`, `screenshots/real-stats-fixture-phone.png`, and `screenshots/trakt-setup-phone.png`. Populated dashboard screenshots use disposable fixture data.

## Still outstanding

Live Trakt authorization/sync/recommendation validation requires the API application and new HTTPS private host. Cloudflare deployment/Access/Google login and physical iPhone PWA checks remain unconfigured. Scanner ingestion/pairing, metadata correction/merge, backup import/restore, private offline mutation reconciliation and cumulative episode-slider parity remain further increments. Existing offline tests cover public code/art caching and the isolated sample preview, not offline editing of the owner's D1 diary.
