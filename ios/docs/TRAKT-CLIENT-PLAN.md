# Trakt-first TwilDiary: plan for approval

Owner decision (5 Nov 2026): **Trakt is the diary.** The app talks to Trakt directly, like a
Trakt client (the Cinopsys model). Cloudflare keeps backups (manual), plus helpers for what Trakt
cannot hold. No phone-side diary to reconcile; the web app and the every-minute Trakt Worker retire.

Cinopsys is closed source (Android only on every listing), so this mirrors its *design*, not its code.

This replaces the authority model of the earlier design in [TRAKT-FIRST-PLAN.md](TRAKT-FIRST-PLAN.md)
(26 Oct: D1 stays the confirmed projection). Its cautions still apply: Undo removes only the specific
Trakt history id, Trakt does not deduplicate plays, and Trakt's published limits must be honoured.

## Why it will be fast

Today a sync compares 3,716 items through Cloudflare in steps of 20 (Free-plan CPU limit), taking
6–24 minutes. Trakt-first does no comparing:

1. `GET /sync/last_activities`: one call says which lists changed. Nothing changed means nothing else is fetched.
2. Only changed lists are fetched, phone → Trakt directly, in a few large calls: `/sync/watched/shows`,
   `/sync/watched/movies`, `/sync/ratings`, `/sync/watchlist`, `/sync/favorites`, dropped shows, notes.
   New plays since the last check come from `/sync/history?start_at=…`.
3. An edit is one POST to Trakt (history, ratings, watchlist, favourites, notes). Trakt's answer is final.

Expected: an unchanged check under a second; a typical refresh a few seconds; first full load
about 10–30 seconds for your library (Trakt allows 500 reads per 5 minutes and 1 write per second for
standard API use; the app waits out HTTP 429 with Retry-After).

## Where each piece of your diary lives

| Diary feature | Lives in | Notes |
| --- | --- | --- |
| Watch history, rewatches, dates | **Trakt** history | Movies and episodes; multiple plays allowed. Trakt does not stop duplicate plays, so the app must. |
| Ratings (all yours are whole 5–10) | **Trakt** ratings | Trakt uses 1–10 whole numbers: no loss. |
| Planned (125 titles) | **Trakt** watchlist | Trakt returns HTTP 420 over the account's watchlist limit; the app reads your limits from `/users/settings` at sign-in and warns. 849 watchlist sends have succeeded so far. |
| Watching / Completed | **Trakt** progress | Derived from history plus episode lists, not stored. |
| Dropped (1 title) | **Trakt** dropped shows (hidden items) | Shows only on Trakt; a dropped *movie* would live in Cloudflare. |
| Favourite titles (2) | **Trakt** favourites | Movies and shows only. |
| Notes (you have 0) | **Trakt** notes | Up to 500 characters; free accounts have a note limit (HTTP 420), VIP unlimited. Title, season, episode and play notes. |
| Season reset to Planned | **Trakt** history removal | Trakt's own "reset progress" is VIP-only; removing that season's plays works for everyone. |
| Anime / anime movie (174 + 63) | Trakt genre "anime", **Cloudflare** for overrides | Trakt has no anime category. |
| File locations, PC scanner, Jellyfin list | **Cloudflare** | As today. |
| Favourite cast, characters, voice actors; AniList profile | **Cloudflare** / AniList | As today. |
| Collection tags | **Cloudflare** | Trakt has nothing equivalent. |
| Trash (removed titles) | **Cloudflare** | Keeps what a removal took from Trakt, so Restore can put it back. |
| Episode/season details, artwork, search, discovery | TMDB via the **Cloudflare** proxy | Your TMDB key stays off the phone. |
| Trakt sign-in | Phone + **Cloudflare** helper | The token exchange runs on Cloudflare so Trakt's client secret is not shipped in the app; the token lives in the iPhone Keychain. |
| Backups | **Cloudflare**, manual | "Back up now" saves a snapshot of your Trakt data plus Cloudflare-only data. "Restore" writes it back. |

The phone keeps an encrypted cache of the last Trakt download (the existing protected cache), so the
app opens instantly and is readable offline. Offline edits wait in the existing outbox and send to Trakt
when online. Trakt is the only target, so there is nothing to reconcile.

## Simkl, WeTrakr, MDBList

> Superseded by "Choose your main tracker" below (owner decision, 5 Nov 2026).

They become copies of Trakt (Trakt wins).

- **Simkl:** has its own Trakt import: one-time free, automatic with Simkl VIP. Updates do not go back to
  Trakt. Option A (recommended, fewest bugs): use Simkl's built-in Trakt import, no app code.
  Option B: the app forwards each Trakt edit to Simkl through the existing outbox.
- **MDBList:** has its own Trakt library sync (watched, watchlist; refreshed daily). Critic ratings are
  read in the app (already built). Same choice as Simkl: built-in sync (recommended) or forwarding.
- **WeTrakr:** its site says the public API is "in development". The integration branch's WeTrakr client
  calls endpoints that are not published, so it is turned off until WeTrakr publishes its API.
  WeTrakr can import from Trakt on its own site.

## What goes away

- Cloudflare diary tables as the live source (kept as the backup format), the 20-row Trakt scan, review,
  apply, baselines and journal (most of `trakt-sync.ts`), the every-minute Trakt Worker, and the web app.
- The Trakt review screen. With Trakt as the diary there is nothing to review.

## Phases

0. **Freeze and safeguard (no app change).** Finish or clear the pending Trakt changes in the old sync,
   then take a full Cloudflare export. Check your Trakt limits (`/users/settings`). Push the 2 favourites
   and 1 dropped show to Trakt.
1. **Trakt client core (phone).** Phase 1 reuses the Worker's existing Trakt connection: `GET /api/trakt/token`
   hands the app a current access token (refreshed on the Worker; the refresh token never leaves). A
   "Direct from Trakt (preview)" check on the Trakt page reads Trakt and compares it with the diary
   without changing anything. Later: own sign-in (PKCE, no client secret needed); the
   last-activities check; fetchers for watched, history, ratings, watchlist, favourites, dropped and notes;
   building the existing Workspace model from them, so current screens keep working; encrypted cache.
2. **Writes.** Watch, unwatch, rate, plan, drop, favourite, notes and season reset go to Trakt (batched,
   1 POST/sec), with duplicate-play protection and the outbox for offline edits.
3. **Cloudflare helpers.** Read/write file locations, tags, anime overrides, trash and people favourites by
   TMDB/Trakt id instead of diary title ids. Manual backup and restore.
4. **Switch over.** The app reads Trakt; turn off the Worker cron and the old Trakt sync routes; retire the
   web app. Keep the old Cloudflare diary read-only for 30 days as a safety copy.
5. **Optional mirrors.** Simkl and MDBList forwarding (if chosen instead of their built-in imports).

## Risks

- **Codemagic trial ends 7 Nov 2026.** Every Swift change needs Codemagic to compile and test. This work
  spans weeks; without billing, iOS builds stop.
- **Trakt availability becomes the app's availability for edits.** If Trakt is down, edits wait in the outbox.
  Reading still works from the cache.
- **Trakt limits:** watchlist, notes and favourites limits on free accounts (HTTP 420). VIP removes most of them.
- **Removals:** the last-activities check reports a change but not what was removed, so a removal triggers a
  full refetch of that list (one or two calls, not a scan).
- **Migration:** anything only in Cloudflare that has no Trakt place must move to the helper tables first
  (phase 0), or it is lost from the app (still in backups).
- **Big change, staged:** each phase ships behind the current app until phase 4, so a failed phase does not
  break the app you use.

## Connecting each service (owner request, 5 Nov 2026)

Every service can be connected two ways, from Profile → its page:

| Service | Sign in | Your own key or token |
| --- | --- | --- |
| Trakt | Trakt page (the Worker's OAuth; the app reads with `/api/trakt/token`) | Your own client ID and access token, or your client ID with a device code |
| Simkl | Device sign-in (AUTH V2, `media:read media:write`; refreshed); an AUTH V1 app falls back to Simkl's PIN | Client ID and access token |
| MDBList | Device sign-in ("Device Code App", scope `write`, 30-day token, refreshed) | API key |
| WeTrakr | Not yet: no published sign-in (`/oauth/device/code` is 404) | App key (`wetrakr-api-key`) and personal access token |

"Sign in" uses TwilDiary's own app client IDs, set once in Settings → APIs → Sign-in apps
(`SIMKL_CLIENT_ID`, `MDBLIST_CLIENT_ID`, `WETRAKR_CLIENT_ID`) and handed to the app by
`GET /api/providers/apps`. Client IDs are public; no client secret is stored or sent. Tokens live
in the iPhone Keychain envelope; refresh tokens never reach plain preferences. MDBList gets either a
Bearer token or `?apikey=`, never both. A Simkl sign-in without `media:write` is refused, because
Simkl silently downgrades to read-only.

## Choose your main tracker (owner decision, 5 Nov 2026)

The main tracker is a choice of Trakt, Simkl or MDBList (Settings → Main tracker). WeTrakr was
removed from the app on 5 Nov 2026 (no published API). The diary model stays the same; each
service is read into the same library model (`TraktLibrary`) by its own reader, so the
comparison, cache and later the screens are shared. Whatever the chosen tracker can't hold stays in
Cloudflare, as tags and file locations already do. The other connected services can still receive
copies of each change (phase 5).

| Feature | Trakt | Simkl | MDBList |
| --- | --- | --- | --- |
| Watch history | Every play, with rewatches | One watch per episode/movie (rewatches need Simkl PRO/VIP) | Watched items |
| Ratings 1–10 | Yes | Yes (`/sync/ratings`) | Yes (`/sync/ratings`) |
| Planned | Watchlist | "Plan to watch" | Watchlist (`/watchlist/items`) |
| Dropped | Dropped shows | Yes (list status) | Yes (`/sync/dropped`) |
| Notes | 500 characters | Memo, 140 characters | No: Cloudflare |
| Favourite titles | Movies and shows | Cloudflare (Simkl's favourites list not used yet) | Cloudflare |
| "What changed" check | `/sync/last_activities` | `/sync/activities` | `/sync/last_activities` |
| Anime | Genre only | Strong (own catalogue; TVDB numbering) | Via TMDB ids |

- Notes longer than the tracker's limit keep their full text in Cloudflare; the tracker gets the
  first part.
- MDBList's read responses aren't documented outside its browser docs; the reader accepts
  Trakt-style and flat items and counts anything it can't read. Confirm against a real account.
- **Switching trackers:** a one-time copy from the old tracker to the new one, with a review of the
  counts first; backups in Cloudflare cover a failed switch.
- **Built so far (phase 1, read-only):** the picker, Simkl and MDBList readers, the tracker-aware
  comparison and the "Direct from … (preview)" check for each.

Sources: Simkl API reference (api.simkl.org: get-all-items, get-activities, add-to-history,
add-to-list, add-ratings); MDBList paths from the open-source mdblist-mcp client
(github.com/j1lt3d/mdblist-mcp) and Scrob (github.com/ellite/scrob/wiki).

## Progress (5 Nov 2026)

- **Phase 1 done:** direct reads and the shadow comparison (Trakt, Simkl, MDBList), deployed server
  helpers `/api/trakt/token`, `/api/providers/apps`, `/api/session/app` (version c0730126).
- **Phase 2 done (not yet tried on the phone):** "Make Trakt match the diary" (`TraktWritePlan`:
  diary watches at their own times, ratings, watchlist, favourites both ways, dropped shows; never
  removes Trakt history) and "Send my edits to Trakt as I make them" (the delivery queue with the
  server's token). The incoming worker links a Trakt play to the diary watch with the same time, so
  these never come back as copies.
- **Phase 3 done (deployed, version c86e2766, migration 0026):** `/api/helpers` (extras by TMDB id)
  and backups (`/api/backups`, Profile → Backups).
- **Phase 4a/4b done (not yet tried on the phone):** "Show my diary from Trakt" builds the diary from
  Trakt plus the server's extras (`TraktDiary.build`); edits in that mode go to Trakt (watches at their
  time, removal by play id, rating, watchlist, favourites, dropped shows) and notes/tags/Queue/Trash to
  the server. Titles only on Trakt join the server diary on their own (posters, episodes); bulk
  status and favourite changes work in Trakt mode.
- **Earlier note, phase 3 (needs production D1 migrations):** helper tables keyed by TMDB/Trakt id for file
  locations, tags, anime overrides, trash and people favourites; manual backup and restore.
- **Phase 4c deployed 5 Nov 2026 10:09 UTC** (main Worker 823c92d8 with `DIARY_RECORD=trakt`; incoming
  worker 2621287a with no cron; previous main version c86e2766). Server read-only until 5 Dec 2026.
  Fix deployed as adc4f573: season progress, the old provider pull and the legacy migration are
  read-only too; refusals use the API's JSON error shape.
  Deployed as 3f58d899 (6 Nov, from dfbbbde): titles carry `updatedAt` (newest change wins against
  Trakt), and backup import into the server copy is refused while a service holds the diary.
  Details: one Worker variable, `DIARY_RECORD` (`server`, `trakt`,
  `simkl`, `mdblist`) with `DIARY_RECORD_SINCE`. Once it names a service, the server's watches and
  ratings are read-only for 30 days (extras stay writable), the Review sync and incoming toggle
  answer 410, the web app shows a notice, and the app (`/api/diary-record`) shows the diary from that
  service. The incoming worker's production config has no cron. Undo: `DIARY_RECORD=server`,
  redeploy; restore the cron and redeploy the incoming worker.
- **Phase 5 done (not yet tried on the phone):** "Make Simkl / MDBList match the diary" (the same
  plan within what each keeps: one watch per episode or movie, no favourites; Simkl moves titles
  between its lists, MDBList uses `/sync/watched`, `/watchlist/items/*`, `/sync/dropped` per its
  published API). Edits mirror to connected Simkl/MDBList from both diaries (MDBList now gets watches,
  ratings and dropped shows; never sent back to Trakt from the Trakt diary). "Show my diary from
  Simkl / MDBList" is a preview with editing paused; edits reach them from the server diary.
