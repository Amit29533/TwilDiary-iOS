# Live Trakt sync audit — 23 October 2026

Status: completed for the connected test-account workflows listed below. The owner explicitly authorized changes in the signed-in Trakt and hosted TwilDiary tabs. This was a test of selected operations in both directions, not an instruction to apply the account's entire review.

## Backups and final state

Before connected-account testing, the diary was exported to `D:/Downloads/twildiary-workspace (1).json`: 9 titles, 43 watch events and 82 episodes. This private local backup was not added to the repository or uploaded.

After the tests, exports `(2)` and `(3)` bracketed disconnect/reconnect. Their SHA-256 hashes were identical. Both contain 15 titles, 50 watch events and 107 episodes. OAuth reconnect restored the same account and the Whole numbers only rule. The remaining **2,198 sync proposals are still awaiting review**. The account is connected, with no scan/apply loop running and no error displayed.

## Bugs reproduced and fixed

| Finding                                                                                              | Change and verification                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Large reviews could not browse beyond 50 changes. Category filtering only examined those first rows. | Added server-side kind/title filtering and cursor pagination. The browser displayed 60 of 100 loaded rows; title searches found records across the review. A 62-change regression verifies no omissions or duplicates and unchanged global counts.                                                                                                                                                                                                              |
| Cloudflare terminated a planning request at its CPU limit.                                           | Worker diagnostics showed `exceededCpu`. Planning now uses five-record batches. Old 20-row page cursors convert once to the equivalent record offset; a regression verifies resumption at record 21, without skipping records. New incoming history lookups/inserts are batched after checking existing provider identities, linked plays and baselines. Both live scans completed; the optimized scan progressed at approximately 500 records per two minutes. |
| A successful history send remained uncertain.                                                        | Trakt now normalizes watch timestamps to minute precision. Matching and candidate SQL now use that precision while preserving exact local timestamps. Remote baselines retain the provider's normalized value. The already-sent movie watch reconciled without a second POST. Regressions cover existing-watch linkage, same-minute repeat plays and repeated sync. [Official API change notice](https://github.com/trakt/trakt-api/discussions/694).           |
| Reload displayed Round for Trakt during an active Whole numbers only scan.                           | Sync status now includes the saved rule, and the selector restores it. Its subtitle explains that changes select the rule for the next scan. Verified on reload and after OAuth reconnect.                                                                                                                                                                                                                                                                      |
| Review rows hid the information needed to choose safely.                                             | History rows now show season/episode and date; conflicts show both TwilDiary and Trakt values. API assertions check the sides and coordinates. Live review was checked at 320, 393 and 1280 px with no document overflow.                                                                                                                                                                                                                                       |
| Connected settings summary told the user to connect.                                                 | Summary copy now distinguishes connected, scanning and ready-to-review states.                                                                                                                                                                                                                                                                                                                                                                                  |
| Apply/Skip were available on paused, incomplete plans.                                               | They remain disabled until planning reaches a reviewable state.                                                                                                                                                                                                                                                                                                                                                                                                 |

## Actual live test results

| Workflow                             | Observed result                                                                                                                                                                     |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Incoming movie history and rewatches | I Want to Eat Your Pancreas imported as one title with two distinct watches, Completed and 100% progress.                                                                           |
| Incoming personal rating             | Its Trakt rating imported as 10, independently of the TMDB community badge.                                                                                                         |
| Incoming watchlist                   | Silo became Planned.                                                                                                                                                                |
| Outgoing watchlist                   | Office Space appeared on Trakt's watchlist; the remote button changed to Remove from Watchlist.                                                                                     |
| Rounded decimal rating               | Office Space retained 7.5 locally and sent 8 to Trakt. Trakt later displayed its personal rating as 4/5, confirming 8/10.                                                           |
| Outgoing movie history               | Horrible Bosses appeared once on Trakt at the original local watch time.                                                                                                            |
| Repeated Apply / uncertain send      | A stale second review refused to send the movie twice. After the timestamp fix, Check Trakt linked the existing history ID. Remote History still showed exactly one viewing.        |
| Whole numbers only                   | Wednesday's temporary 6.5 rating produced a blocked proposal with only Skip. Skip preserved the decimal locally and made no rating send. The local rating was then restored to 6.0. |
| Keep TwilDiary conflict              | Office Space displayed TwilDiary 6 / Trakt 2. Keeping TwilDiary changed Trakt to 6 (3/5 in its UI).                                                                                 |
| Use Trakt conflict                   | Horrible Bosses displayed TwilDiary 7 / Trakt 10. Using Trakt changed the local personal rating to 10.                                                                              |
| Direct remote watch → local progress | A watch logged directly on Trakt imported into Office Space as one watch, Completed, 100%, retaining rating 6. Dependent watchlist planning did not reset its progress.             |
| Outgoing episode                     | Wednesday S1 E4 exported as that exact episode. Trakt History displayed S1 E4, Woe What a Night, at the correct original time.                                                      |
| Incoming episode                     | Spooky in Love S1 E6 imported with its original 19 October 2026 date. Recently watched displayed those exact coordinates and date.                                                  |
| Apply all / Pause                    | Apply all started, and Pause stopped after one completed history import: Plastic Memories S1 E6. Pending proposals decreased by one. No further loop continued.                     |
| Disconnect / OAuth reconnect         | Disconnected UI appeared, reconnect completed through OAuth for the same account, and the entire exported diary remained byte-for-byte identical.                                   |
| Responsive review                    | History context, selectors, search and review controls rendered at 320, 393 and 1280 px with document width within the viewport.                                                    |

Evidence: [Imported episode and original date](screenshots/trakt-live-imported-episode.png).

The test-created/imported titles are Office Space, Horrible Bosses, I Want to Eat Your Pancreas, Silo, Spooky in Love and Plastic Memories. Wednesday gained the explicitly tested S1 E4 watch and has personal rating 6 after the temporary decimal test. These records remain available for inspection; the original backup remains local.

## Verification and deployment

Final `npm run verify` passed: zero type-check errors/warnings, **341 unit/database/controller tests**, production build and **3 compiled PWA tests**. Total: **344 automated tests**. The isolated live HTTP runner also passed **11/11 workflow groups** against the final source. Full dependency audit remains at zero known vulnerabilities; no dependencies were added for these fixes.

Hosted version: `c5178ac6-c2ff-4120-a5ec-c598c8d26852`. No database schema migration was required. The existing Access protection is retained. Wi-Fi uses the same final source on port 5180.

## Limits of the live pass

Permanent history deletion, lost-response injection, provider throttling, invalid credentials and concurrent mutation edge cases were exercised with isolated database/provider fixtures. No permanent removal of existing Trakt history was performed. The live pass checked actual imports, sends, conflicts, repeat-send protection, pause/resume and account reconnection.

There is no separate global one-way-mode switch in the current UI. Incoming and outgoing proposals are reviewed per item, and both directions were tested. Applying all ready changes remains global; category and title filters only change which proposals are shown.

Physical iOS touch/WebKit and Capacitor/IPA packaging remain the device-specific checks listed in the web release audit.
