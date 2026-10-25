# TwilDiary build54 — iPhone test checklist

**Install:** D:/Downloads/TwilDiary-native54-codemagic-passed.ipa
**Version to test:**54. Builds55(cache optimization) and56(carousel rotation) are not in this IPA.

The complete Codemagic regression passed. These checks establish actual phone,
provider, gesture and visual behavior that simulator tests cannot fully prove.
Use a disposable movie/show for changes and restore it after each test.
For each item mark PASS, FAIL or NOT TESTED. Report your iPhone model, iOS
version, theme and build number once. A short screen recording is best for
animation/gesture failures; screenshots are best for clipping and bad layouts.

## First: previously reported problems

- [ ] **T01 — Compact header:** Open a bright-artwork title and a long-name title. Slowly scroll the poster/name out and back10times, including tiny reversals at the transition. The compact poster/name stays centred in its available space, with no shudder, flicker, jumping height or artwork appearing behind lower rows. Record this even if the problem is intermittent.
- [ ] **T02 — Back gestures:** From History, Explore, Files/drives, Appearance, Trakt, TMDB and About, try both Back and a full rightward swipe starting in ordinary page content. Try a short swipe and cancel it. Completed swipes return one level; cancelled ones keep the page. The navigation bar travels smoothly with the page, without disappearing then popping back.
- [ ] **T03 — Search/keyboard return:** Search on Home, open an online result, then start/cancel Back and complete Back. Repeat with a Library result and from cast filmography. The retained search appears directly, with the same query/results and no keyboard behind the moving title or flash of Home.
- [ ] **T04 — Bottom navigation:** Tap every tab repeatedly; hold Library and slide across all five tabs, release on a target, then release outside the bar to cancel. Also swipe right to the next root tab and left to the previous one. Check no bar flicker/stutter, accidental extra switches, or wrapping past Home/More.
- [ ] **T05 — Expanded episode grid:** Choose grid, expand several long episode summaries and scroll. Artwork, caption, rating, watched control and summary stay together; no giant empty holes, horizontal overflow, overlap or distorted image. Switch back to list and check controls still work.
- [ ] **T06 — Notes targeting:** Glance → … → Notes opens the editor itself. Repeat from the title's … menu. Wait for late cast/recommendations to load: the editor stays in view. Type/save, go to cast and back, then reopen: the saved text remains.
- [ ] **T07 — Toasts/loading:** Perform a watch action. Undo appears above the nav bar without moving content and closes after roughly4.5seconds when untouched (8seconds with VoiceOver). Hold it: it stays available until release. Test Undo and ×. Passive Saved diary/Refresh banners should not cover pages, and ordinary loading should not insert/remove a row that shifts the menu.

## Watch progress, dates and history

- [ ] **T08 — One episode + Undo:** Note the count, mark the next aired episode watched, check count/pieces/next episode/History, then Undo. Everything returns to its original value with no extra viewing.
- [ ] **T09 — Explicit episode rewatch:** Expand an already watched episode and tap **Log rewatch**. History gains one new viewing. Undo removes only that new rewatch; the original viewing and watched check remain. This is the new visible action in54.
- [ ] **T10 — Slider:** Move the episode-piece slider forward and backward a few episodes. Check exact count, percentage, watched rows and Undo. Check past watches are not redated and unrelated seasons stay unchanged.
- [ ] **T11 — Current season:** On a multi-season show, use Glance → … → **Mark complete**. Only the selected/current season completes. Undo restores it; the next season must not silently become watched. Check caught-up/unaired episodes cannot be logged prematurely.
- [ ] **T12 — Movie:** Log a disposable movie, log an explicit rewatch where offered, remove the latest viewing, and test Undo. Older movie viewings remain intact. Rapid taps while one save is pending must not create accidental duplicates.
- [ ] **T13 — Watch date:** Set yesterday or another past date, log a watch and check its History day. Test today, month boundaries and changing a History date range. No date-field overlap, wrong-day shift or ambiguous selected preset.
- [ ] **T14 — History controls:** Test Any date/Today/Last7days/This month, custom from/to, Unknown dates, local title filter, Clear filters, Show more, grid/list and opening/returning from a row. The selected filter is clearly visible, counts make sense and separate rewatches remain separate entries.

## Home, Glance and Library

- [ ] **T15 — Whole-card opening:** On Home's continuation card and Glance, tap the cover background, poster and title separately. Each opens the correct show. Watch buttons, … and horizontal card swipes must retain their own actions.
- [ ] **T16 — Independent pending state:** Tap +/− on one Glance show with a slower connection. Only that card shows its pending action; other shows remain usable. Switch Anime/Movies/Shows and back: counts do not reset to zero or refetch with jumpy loading on every visit.
- [ ] **T17 — Glance menu:** Test Favorite, Queue, Dropped, Mark complete and Notes on a test title. Changes agree with Library. There is no redundant Open title item. Restore the title's original state afterwards.
- [ ] **T18 — Library filters/persistence:** Combine category, status, genre, drive and text; clear them. Test sort, grid/list and genre shelves. Switch tabs and restart the app: layout/sort should remain. Cover buttons and selection controls must not collide.
- [ ] **T19 — Public ratings:** In Settings switch TMDB → Trakt → TMDB. Library badges use public community scores, one decimal and the compact translucent style. They never substitute your personal rating. A missing provider score may be unavailable, but must not spin indefinitely or freeze Library. Report how long Trakt takes.
- [ ] **T20 — Home links:** Try Queue, Disk Map/Locations, Fix mismatches, This week day bars, Stats, Planned, upcoming episodes and recently watched. Each opens the matching data/season/day and Back restores your place. Swipe the continuation cards manually. Automatic carousel rotation is a later56feature; do not expect it in54.
- [ ] **T21 — Trash:** The Library Trash button opens its own page. Move a disposable title there, confirm it leaves ordinary Library/Glance, restore it and confirm history/notes/ratings remain. Permanent-delete/Empty Trash testing is optional and only for disposable data.

## Title details, discovery and Information

- [ ] **T22 — Artwork/synopsis:** Art reaches behind the top chrome; lower name/ratings stay readable over bright art. More expands only the remaining synopsis beneath the opening lines. Check no missing/repeated words, strange blank line, clipping or full-text jump. Less collapses correctly.
- [ ] **T23 — Title edits:** Change your rating, clear it, add a note, change status, Favorite/Queue and return/reopen. Personal rating edits must not change watch count. Check a long show name and a movie without runtime/artwork.
- [ ] **T24 — Spoilers/seasons:** Open an unwatched episode before/after revealing its details. Revealing one must not reveal all other episodes. Change season and return from cast: chosen season, expanded episode and unsaved Notes draft stay intact. Toggle Hide spoilers in Settings and verify the result.
- [ ] **T25 — Information:** Open ⓘ on a known Trakt-matched title and an unmatched one. Real stats/sentiment appear or an honest unavailable/retry state. Drag the sheet higher and scroll: glass transparency and dark sentiment cards remain, text stays readable, swipe-down dismisses and the title underneath is unchanged.
- [ ] **T26 — Explore/search consistency:** Search from Home, Library, Stats and More: both local Library and online TMDB results should work. Glance search must stay limited to Glance. Test nonsense/empty queries, clearing, changing queries quickly and a provider failure; existing local results should remain usable.
- [ ] **T27 — Import/manual add:** Search a disposable online title, review and add it. It opens the saved title and appears once in Library. Reopen the same result: no duplicate import. Test a manual title's year validation, category, rating and planned status. Test restoring an already trashed matching title if available.
- [ ] **T28 — Cast/related:** Open a cast person, biography/facts and Show more/Known for/Movies/Shows shelves. The grid/list switch sits beside the heading, the removed filter panel is absent, long names wrap, and Back/swipe returns to the original title. Recommendations should retain cached content while refreshing and open the correct title.
- [ ] **T29 — Surprise:** Open a random pick from Home and via the logo. Background taps keep it open; a deliberate swipe or Close dismisses it. Pick again should avoid an immediate repeat when alternatives exist. The Planned picker stays within eligible planned titles and the dialog fits the screen.

## Stats, files, settings and connection

- [ ] **T30 — Stats:** Test every period/range/year option, tap chart buckets and day cells, open undated watches and backlog/genre rows, then return. Home → Stats starts Today. Selected controls are legible, dates do not collide, zero/empty periods remain usable and day drill-down agrees with History.
- [ ] **T31 — Files/drives:** Open drives, folders, saved locations and scanner mismatches; test filters, grid/list, path copy, title links and Back. Existing PC data displays correctly. Phone is not expected to scan Windows drives. If resolving a disposable mismatch, only its location changes, not watch history.
- [ ] **T32 — Themes/settings/export:** Try all six themes and public-rating/spoiler preferences, then restart. Check rounded buttons, readable selected states, badges and Liquid Glass controls across screens. Export JSON through the native file sheet and cancel once; returning must work. Verify the resulting file opens and represents your diary; no account credentials should be included.
- [ ] **T33 — Authentication:** Relaunch an existing signed-in session. If you choose to test sign-out last, sign in again through real Cloudflare2FA; also cancel and retry the sign-in sheet once. No endless loading, stale callback closing a new attempt or loss of previously saved server data.

## Trakt: test separately from ordinary UI

- [ ] **T34 — Manual comparison:** Open Trakt and record the status text. While **Preparing review/comparing**, Apply/Skip are intentionally unavailable until comparison completes; Pause/Continue/Stop should be explained and usable. Once review is ready, legitimate Apply/Skip/conflict choices become available. Report the exact stage/count and elapsed time if progress keeps growing without finishing. Do not apply a whole-library batch just to test a button.
- [ ] **T35 — Reviewed sync directions:** On disposable changes, test one incoming watch/rating/watchlist item, one outgoing proposal shown in the review, one Skip, and one explicit conflict choice. Verify only the reviewed choice changes, retry does not duplicate it, and filters/grid/list do not alter pending decisions. Already-saved data must remain when leaving/reopening.
- [ ] **T36 — Automatic incoming watch:** With Incoming watches ON, first check whether it says paused by an active manual scan/review. Automatic import correctly waits while that review exists. When no review is active, create ONE completed episode/movie play in Trakt, note the timestamp, wait about1–2minutes, then open/resume TwilDiary. Check progress and exactly one matching History event, then reopen twice to check no duplicate. Refresh status and report Last checked/error/pending/review text if it does not arrive. This is a measured test, not a one-minute guarantee.
- [ ] **T37 — Existing local match:** If convenient on a disposable episode, log it locally and let the matching completed Trakt play arrive within6hours. One unambiguous existing watch should be linked, retaining the local watch date/count. Multiple possible local matches should require review rather than adding a duplicate. Ratings/watchlist/deletions are reviewed sync; the automatic incoming feature is completed plays only.

## Offline, interruption and actual iPhone polish

- [ ] **T38 — Offline/reconnect:** After loading the diary online, enable Airplane Mode and relaunch. Saved pages, tabs and details should remain browsable. A new write must fail honestly rather than pretend success. Reconnect and refresh: no duplicate watch, accidental sign-out or missing previously confirmed data. Some online metadata/artwork may be unavailable offline.
- [ ] **T39 — Interruptions:** Put the app in background/lock the phone during a load and during a disposable save; reopen. Check no stuck dim buttons, frozen overlay, duplicate event, stale sheet or lost draft. If a save succeeded but its refresh failed, use its recovery Refresh rather than logging it again; expect one viewing and working Undo after reconciliation.
- [ ] **T40 — Real performance:** Spend a few minutes scrolling a large Library, Glance, episode lists/grids, History and Explore. Switch themes/tabs repeatedly. Record any hitch, image flashing, repeated jump/loading, hot-phone/battery behavior or input lag, with the screen/theme and approximate library size. Build55performance changes are not included yet.
- [ ] **T41 — Accessibility:** Increase system text size, enable Reduce Motion, then Reduce Transparency; check title/ratings/dates/buttons/sheets remain contained and legible. With VoiceOver, try tabs, search, episode controls/Undo, chart day buttons, Information and closing dialogs. Focus should not jump behind a modal; motion/haptics should respect device settings.

## Send results back

You can send results in batches. Start with T01–T07 and T34/T36.

Example:

Build54 · iPhone17Pro · iOS27 · Liquid Glass
T01 FAIL — header shudders on slow upward scroll, clip attached
T02 PASS
T09 PASS — rewatch added one and Undo kept the old watch
T34 NOT TESTED
T36 FAIL — waited3minutes; status says “…”; one play recorded at HH:MM

For a failure include the shortest steps to reproduce, expected/actual result,
whether it repeats, and a screenshot/5–15second clip when useful. Keep a copy
of the original watch count/date for tests that change data. Network/provider
outages and an active manual-review pause should be reported with their exact
message rather than assumed to be a UI failure.
