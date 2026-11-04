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
