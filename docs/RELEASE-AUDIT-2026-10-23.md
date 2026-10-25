# Final web application audit — 23 October 2026

Status: web audit completed. The source review, disposable live API workflows, desktop browser walkthrough, responsive checks and production verification are complete. The subsequently authorized [connected Trakt test-account audit](TRAKT-LIVE-AUDIT-2026-10-23.md) is also complete. Physical iOS and packaging remain separate release gates; this report does not certify every possible interaction or device.

## Isolation

`node tooling/audit-workspace.mjs` copies an explicit source/configuration allowlist to `%TEMP%/twildiary-release-audit-app`. It excludes the owner's database, personal Trakt authorization, Access configuration and browser storage. Only the public provider application's required TMDB token/Trakt app ID are copied, without printing them. Its independent D1 database runs on loopback port 5182. Initial web-audit mutations used this disposable app. The later connected-account pass used the hosted test account with the owner's explicit authorization and a prior diary export, as detailed in its report.

The initial copy inside `.local` was incompatible with Vite's filesystem deny rules. It was moved to the temporary directory before the walkthrough. Old console errors from that abandoned copy were excluded; a clean browser tab traversing the final core screens logged no errors or warnings.

## Fixed during this audit

- Cast filmography and full Explore list year fields now update on input. Previously the field could show a new year while displaying the previous unfiltered results, and Reset could leave the typed value behind. Valid/invalid years and Reset were verified in the browser.
- Public Trakt rating cache uses a reactive `SvelteMap`. This avoids inherited-object keys such as `constructor`, prevents prototype-derived false cache hits, and repaints badges when asynchronous public scores arrive. The response map also avoids inherited keys. Browser confirmation: Your Name's Trakt score appeared as 8.9 after loading, independently of the personal rating.
- Artwork links support Space to enter collection selection, so bulk actions can be reached from the keyboard. Enter remains ordinary navigation. Repeats/modifier keys are ignored; timers and listeners are cleaned up. Browser selection, confirmation, favourite, Trash and restore passed.
- Partial manual-add completion now reports that the title was saved but its watch progress could not be completed, instead of hiding that outcome behind a generic connection error. Retrying as Planned reused the saved title without duplication.
- Stats aggregation no longer sorts history or parses the same dates repeatedly when that work is unnecessary. A single local 20,000-watch benchmark dropped from approximately 610 ms to 217 ms. This is a local measurement, not a cross-device performance guarantee; calendar/DST/future-date tests passed.
- Legacy workspace migration validates malformed records before any batch writes, including null records, text/array types, runtime/date values, episode parents and file-location fields. Invalid imports return validation errors instead of incidental server exceptions.
- The mismatch-review header no longer overflows a 320 px viewport. It follows the settings navigation convention with no back arrow, and long shared header titles can shrink with an ellipsis. The fixed screen was rechecked visually at 320 px.

## Browser walkthrough

| Area               | Interactions verified                                                                                                                                                                                                                                                        |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Home               | Visible continue-watching action and Undo, carousel keyboard pause, random-pick dialog, upcoming empty state, This week → Stats opens Today.                                                                                                                                 |
| Library            | Categories, combined status/genre filters, search/empty/clear, list/grid, genre shelves and See all, public TMDB/Trakt scores, keyboard selection, bulk confirmation, favourite, Trash and restore.                                                                          |
| Show/anime details | Planned resets progress with Undo; Completed fills progress with Undo; season selection survives cast navigation and Back; rating saves; notes save; episode action and Undo; spoiler preference masks/reveals actual catalogue names/images; locations disclose full paths. |
| Movie details      | Dated watch, completed status and slider, second viewing, removal of latest viewing only, Undo restores it.                                                                                                                                                                  |
| Glance             | Category/search filtering, increment/decrement and Undo, progress updates without desktop page repositioning.                                                                                                                                                                |
| Stats              | Today, Week, Month, Year, 7D/30D/90D/1Y/All synchronization; inline year selector; known two-watch runtime of 212 minutes; chart selection reveals titles; streak/backlog display; top-five genres expand to remaining genres.                                               |
| History            | Review unknown dates, month preset, date bounds, title search, empty result, Clear and pagination.                                                                                                                                                                           |
| Explore/cast       | Actual remote shelves and title details, full-list pagination 20 → 40, year validation/reset, cast filmography pagination 40 → 73, cast year filtering, import into Planned, return navigation.                                                                              |
| Files/scanner      | Drive filter survives return navigation; location disclosure and copy feedback; a disposable unmatched Z: folder was matched to an existing title and appeared under Files. No owner filesystem scan was launched.                                                           |
| Settings           | All six themes, persistence on reload, public-rating source, spoiler preference, export/download (schema version and content checked), TMDB status, disconnected Trakt state, About and attribution.                                                                         |

The 14 main local screens were also rendered at widths 320, 393 and 1280 px (42 visits). The only document-width overflow was mismatch review at 320 px; it was fixed and rechecked. Explore and cast layouts were separately exercised on narrow viewports. All six themes were checked at 320 px. Viewport testing uses desktop Chromium, not an iPhone emulator.

Evidence: `screenshots/release-audit-stats.png` shows the final Year controls, chart and floating glass navigation using disposable history. The ignored `.local/audit-responsive-results.json` retains the initial measurement matrix, including the mismatch overflow before its fix.

## Automated and live verification

- Final `npm run verify`: zero Svelte/type errors or warnings; **341 unit/database/controller tests passed**; production build passed; **3 compiled service-worker/PWA tests passed**. Total: **344 automated tests**, including the connected-account fixes and regressions.
- Formatting checks passed for all audit-edited product and test files.
- Full `npm audit`, including development dependencies: **zero known vulnerabilities**.
- `node tooling/audit-http.mjs`: **11/11 live workflow groups passed** against the disposable Vite/D1 server after the logic fixes. It checks 18 current screen routes plus a legacy redirect; workspace paging/read APIs; title edits and stale-version conflicts; movie retry/rewatch/reversal; atomic Planned reset/Undo; series/spoiler operations; bulk Queue/favourite/Trash/restore/disposable purge; malformed input and cross-origin write rejection; actual TMDB search/import idempotence; actual Trakt public ratings; discovery/cast/related metadata.
- Detailed logs/results remain ignored under `.local/audit-final-verify.log`, `.local/audit-sync-live-verify.log` (latest), `.local/audit-http-results.json`, `.local/audit-http.log` and `.local/audit-final-all-dependencies.json`.

The source pass covered tracking/status/Undo, navigation and view memory, date/runtime/streak aggregation, library/public ratings, metadata discovery/import, settings, provider transports, scanner/drive paths, authentication boundaries and PWA caching. There were no remaining TODO/FIXME/“not implemented” markers found under `src` during the final pass. This is evidence of review, not proof that every branch is defect-free.

## Checks that still require their real environment

- Physical iOS 27 Home Screen PWA: touch swipe/release, native selectors, keyboard/safe-area behavior and the previously reported wordmark blur. The owner explicitly deferred that blur until the Capacitor port. Existing snapshot/scroll and release-click fixes were preserved. Desktop automation cannot certify those gestures.
- Capacitor/iOS signing and GitHub Actions: no native project/IPA was built as part of this web audit. WKWebView navigation, external auth callbacks, offline startup and packaging require a dedicated port validation pass.
- Trakt OAuth, scan review/apply/disconnect, incoming/outgoing history/ratings/watchlist, conflicts and retries were subsequently verified against the explicitly authorized connected test account. Permanent history removal and injected provider failures remain isolated-fixture tests. See the [live audit](TRAKT-LIVE-AUDIT-2026-10-23.md) for exact coverage and remaining unapplied proposals.
- A real Windows scanner run and server availability transitions require the scanner/device environment. Matching and files UI were exercised with a disposable scanner record.
- Real network loss/service-worker lifecycle behavior was exercised by the compiled-worker tests; no physical-device offline launch was certified.

No data-schema migration, commit or push was needed. Authorized connected-account test changes and local backups are listed in the live audit. The final source is available on Wi-Fi port 5180 and the existing private hosted app.
