# Native parity status — work in progress

## Current evidence —61delivered;62qualified/GitHub running;63candidate/64draft

Native61 source8c9514094e96498855b83034c52c4b4349af8fee / CM6ade36de4a72334e32e5107f
has a complete official pass:219native,17focused,10early and53primary UI tests,
plus3layout cases on each iPhone17eand17ProMax. Simulator/device Release compile
with zero warnings. Its physical IPA, checksum and eight unedited screenshots
are retained in releases/native61-codemagic-candidate.json and
screenshots/step-10/build-61-codemagic-passed. This proves the named automated
flows, not every phone/edge case or pixel-perfect production acceptance.

Native62 / CM6ade49474a72334e32e515c7 / source50134fc has passed219native,
17focused and10early UI plus physical Release/resource checks. Its actual app
contains the new required-reason privacy manifest and excludes test fixtures.
Official complete CM62check121268303837is successful for exact50134fc. Its final
artifact archive download remains pending browser access. Exact source62has
advanced toios-native; independent GHA40228034161passes candidate-proof plus
407backendtests/typecheck/Workerbuild and is compiling native targets.63is a
separate running cold-quota candidate (228native/54primary source cases).64is a
local parent-reference/one-read-retry draft (232native/54UI/69Core source cases),
with408backendtests passing. Neither63nor64has runtime acceptance yet.

| Area | Native61 automated evidence | Remaining practical limit |
| --- | --- | --- |
| Root navigation | All five body swipes both ways, boundaries, native bar hold/slide/cancel, per-tab return | Physical touch physics/frame pacing/VoiceOver |
| Home | Carousel auto-advance/pause/return, cover actions, shortcuts, empty random pick | Physical scroll with a large real library |
| Library | Composed filters, sort/layout relaunch, multi-select, Queue, Trash/restore, public ratings | Live provider availability is separate from fixture correctness |
| Glance | Per-card pending actions, category reuse, cover/menu, current-season completion, Notes and Undo | Phone haptics and rapid gesture comfort |
| Saved title/episodes | Segments, watch/range/movie Undo, metadata/spoilers, notes, grid thumbnail check targets, compact header actions | Physical slow/reversing header transition and largest text |
| Explore/search/cast | Search/library+TMDB scope, retained return, no keyboard behind Back, cast filmography and grids | Live metadata/network latency |
| Stats/history | Calendar ranges, empty/unknown dates, source golden rules, chart/history navigation | Largest Dynamic Type and VoiceOver chart reading |
| Information | Overall stats/sentiment state, empty/error/retry, detent scroll and dark cards | Physical transparency at both detents; screenshot is not material-motion proof |
| Locations/settings | Files/scanner review fixtures, native Back, inline search, appearance/source settings | Windows ingestion remains PC-only |
| Manual Trakt | Reviewed safe/conflict actions,2,000-change worker, tab continuation, Pause/resume, quotas/read-back |63cold-process quota recovery is not yet runtime accepted |
| Incoming Trakt | Enable/disable/review UI; owner previously confirms setting survives restarts | Live scheduled latency/active Free CPU and hosted optimized-schema rollout |
| Offline/session/cache | Owner-bound authenticated AES-GCM cache, off-main sealing/cold read, sign-out and late callback fences | Real-device cold launch/lock/interruption/battery |
| Database/workflow |407independent GHA API/shared-rule tests, typecheck/Workerbuild; local migrations/query plans and16tool cases |0014–0016not deployed; independent native GHA still running |

The Home automatic carousel is implemented and passed61; the earlier report of
its absence is obsolete. The bottom navigation is now first-party SwiftUI
TabView Liquid Glass by explicit owner direction, an intentional departure from
the original web capsule. UI acceptance uses native XCUITests; further web/PWA
walkthroughs are outside the owner's clarified audit scope.

The following build-by-build notes/table are historical. Their old pending/
custom-navigation/synchronous-cache statements do not override this current
checkpoint. ROADMAP.md remains unfinished until the remaining evidence is met.

## Historical verification and owner-directed native changes (25 October)

Codemagic native43 (d086023 / 6add74934a72334e32e4e58d) passes zero-warning compilation,167native units,47primary UI cases and3layout cases on each extra phone. This is a test baseline, not pixel-perfect/all-device production acceptance; later owner-video defects are being repaired in44. GitHub43 remains independent and pending. Backend incoming/community rollout is now authorized and deployed as recorded in PROGRESS.md; older no-deploy statements below are historical.

Owner-directed changes beyond the old web design: root rightward-next/leftward-previous tab swipes; destination-owned chrome that travels with native push/pop; compact identity hysteresis/fade; persistent Information material with black sentiment cards; removal of incidental loading rows; recommendations switch beside heading; removal of filmography filter panel in favour of a single heading-level grid/list control.44 source621e196 is under validation; do not describe these as passed43 screenshots or completed visual parity. Current finite Trakt comparison UI translates a record offset; it never applies partial proposals or cancels the owner's active hosted review.


Build27 update: Core54 and zero-warning simulator compile pass; earlyUI7/8 pass, now including complete Files/scanner and manual-movie Glance log/Undo. Only surprise modal accessibility bounds fail. No Release/IPA/full/all-phone execution or acceptance. Build28 adds a real bounded modal container and the documented duplicate/auth/reveal hardening; runtime acceptance is pending.

Historical evidence: build 26 (40104599130 / 71ebe48) passes 54 Core tests, zero-warning simulator compilation and 5/8 early UI regressions, including full-bleed moving hero/Notes, Explore native Back, retained/scoped search and real watch/slider/Undo/movie behavior. It fails Files final-action clearance, manual movie Glance final-action hit testing and surprise accessibility bounds, so Release/full/all-phone tests are skipped and it is not accepted. Build 27 prepares bottom clearance and explicitly measured modal bounds; runtime acceptance is pending. Prior historical results below do not imply these new gates pass.

Product source: the web /preview code at b43454e. Active native source: Amit29533/TwilDiary → ios-native → ios/. No hosted changes or deployments.

Build 25 / 40098826990 / 6130cdf completed: 54 Core + 99 native unit tests and 33/40 primary UI pass, zero build warnings, passing simulator/device Release and early real watch/slider/Undo/movie regression. All three primary Layout cases, tab scrub/cancel, held Undo, per-card pending/cache/category behavior and title-menu/location flow pass. Seven remaining primary UI failures (safe-area art, recovery test timing, Files content scrolling, manual sheet/keyboard navigation, carousel-vs-Back gesture targeting, surprise container identity and Clear focus) are diagnosed in root PROGRESS.md. Extra-phone checks are skipped; this is not an accepted release. Build 26 prepares corrections and runs these regressions in the early gate, followed by the complete suite. No product changes from the second external review brief are included.

**Build 24 / 40096455786 / 8e15e9a** passed 51 Core tests and zero-warning simulator/test-bundle compilation. Its early Undo test touched after the 4.5s toast expiry because it took a screenshot first. The actual write succeeded; Undo had already closed. Later native unit/full UI/extra-phone/device Release stages were skipped. Build 25 removes slow captures before time-sensitive Undo actions, preserves a separate appearance/expiry check, and pauses the timer while the toast is touched. This does not bypass the early gate or extend normal idle expiry.

**Build 23 / 40093347382 / d7d9f87** passed 51 Core + 89 native unit tests, the real watch/slider/Undo/movie preflight, and 29/31 primary UI cases. Simulator and device Release compiled with zero warnings. Remaining UI failures were an undersized genre-icon accessibility frame and a parent location disclosure identifier hiding child action identifiers. Both are corrected in build 25, with acceptance pending; extra-phone suites were skipped. Build 22's sole outdated concurrent-cursor test is corrected and passes in 23.

Last fully green remains **build 14 / 40056346004 / 9c4b527**: zero-warning builds, 25 Core + 32 native unit + 9 UI tests, 29 screenshots and a verified unsigned IPA. That is older source, not proof that the expanded port is finished. Build 22's unsigned arm64 IPA was provided as an explicitly unaccepted trial; build 24 did not produce an IPA.

| Screen / area | Native work present | Remaining parity / validation |
| --- | --- | --- |
| Shell | Fixed headers, source vector icons, independent tab stacks, six accents and floating capsule | Base-phone theme/search checks pass in 23; the Library genre-control frame assertion failed and its correction awaits 25. Compact/large acceptance and complete visual comparison remain open. The new native scrub lens awaits 25. Physical transparency/keyboard/gesture review remains. |
| Home | Continue cards, shortcuts, weekly metrics/day links, planned pick, upcoming and recent history | Random scope/no-repeat/empty Add and Stats→Today pass in 21. Upcoming season/Episodes navigation passes in 23. Exact lower-section/card geometry, carousel automatic rotation and accessible previous/next/pause parity remain open. |
| Library | Category/status/genre/disk/query, public ratings, grid/list/genre shelves and reviewed bulk actions | Search/filter composition/tab restoration, Queue→Trash→restore→delete and rating preference/provider outage pass in 21. Public-rating/list-card/projection regressions pass in 23; exact Library genre-control bounds remain pending the build-25 correction. Favorite/tag/availability route presentation and all-size/visual acceptance remain open. |
| Title movie/show/anime | Clear art/ratings/status; episode pieces/slider versus movie logger; lazy seasons, spoilers, dates/rewatches, versioned Undo, notes/locations | Watch/Undo/real slider/movie history, rating/notes draft and single-episode reveal pass in 21. Linked-season routing and Notes/empty-location reveal/scroll pass in 23; the Files/Copy descendant identifier correction awaits 25. Full hero/panel/row visual parity and stale/rapid/network transition matrix remain open. |
| Catalog | Combined query/identity/paging, source hero, lazy season preview/pieces/reveal, category selection/import/Restore routing and manual creation | Search/review/cast, series seasons/import and manual year/status/rating/saved navigation pass in 21. Full provider error/empty/retry and all-size visual acceptance remain open. |
| Explore | Source daily choice/four shelves/section grids, unwatched list, Trakt recommendations, genre/year/rating/sort/paging | Entry and shared search/filter behavior have 21 coverage and source golden fixtures. Every filter combination, provider empty/outage screenshots and all-size visual acceptance remain open. |
| Cast/person | Biography/facts/source-role return, server/Known-for/media shelves, filtered filmography and bounded metadata cache | Catalog cast profile/notes return pass in 21. Forty source projection cases agree in Core. The complete Person shelf/source-role/filmography flow passes in 23 after the column-pitch assertion correction. Loading/error/long-name/all-size visual review remains. |
| Glance | Source-order watching cards, category/query, remaining time, +/-/swipe/Undo | Exactly-one swipe watch, Undo and card position pass in 21. Movie Log watch/Watched and manual-movie Glance log/Undo pass in 23; per-card pending state, cache retention, whole-cover taps and expanded menus await 25. Physical gesture timing/scroll smoothness and complete visual matrix remain open. Current web has no waiting section or sort control. |
| Stats | Source date/range/year aggregation, charts/drilldown, streaks, heatmap, backlog and genre rows | Seventeen source calculation scenarios agree in Core; calendar/empty bucket/undated history, original collision-only range bar and Home→Today pass in 21. Full all-size visual/accessibility acceptance remains. Current source has no hourly chart. |
| History | NFKC query, date/recorded/id order, inclusive/open ranges, Unknown dates, rewatch evidence and 12-row paging | Nineteen source golden scenarios agree in Core. Full-row navigation, filters and history return/paging pass in 23. Stronger selected presets and native date-sheet containment await 25; full all-size/visual acceptance remains open. |
| Files & drives | Device/volume summaries, filters, folders/evidence/path copy, Library link and scanner review | Scanner resolution publishes a location without changing watches in 21; header Done/search/navigation work. Full filters/empty/error/retry/paging and all-size visual matrix remain open. PC creates scans; phone reviews existing data. |
| Trash | Shared Library controls/layout and reviewed restore/delete/Empty Trash | Bulk Queue→Trash→restore→delete passes in 21. Source heading/canvas are included in 23; broader stale/conflict/empty/error coverage remains. Native adds a confirmation before the explicit destructive Empty Trash action. |
| More/settings | Tracking/region/public rating preference/export/storage/About, provider boundaries, six themes | Theme selection/shared search and actual Trakt summary state pass in 21. Source Appearance two-column grid and selection pass in 23 and have diagnostic screenshot review. Every option/export sheet and complete visual regression remain open. Current source has no import or automatic-backup settings. |
| Trakt | Existing server PKCE flow, status/scan/step/pause/cancel, review/filter/paging/cooldown and explicit local/Trakt/skip choices | Safe apply and explicit conflict choice pass in 21; fixture controller/transport rules pass. Full direction/type/uncertain/retry UI matrix, actual provider/device auth and visual parity remain open. Synthetic provider performs no HTTP requests. |
| Offline/auth | Keychain, restricted authenticated transport, owner-scoped encrypted snapshot, complete reload/generation guards and retry identities | Transport/cache/session regression passes in 21. Confirmed-save/failed-refresh recovery, concurrent complete snapshots and per-section repeated-cursor bounds pass in 23. Queued different-card/session-cancel and per-title read-cache tests await 25. Real phone 2FA/LiveContainer persistence/background/offline transitions remain unverified. Cache/JSON work still runs on the main actor. The web has no offline write outbox. |

PC-only boundary: scanning/ingestion and provider credential editing remain on the existing Windows/server side, as on mobile web. Native presents saved mappings, scanner evidence and reviewed resolution. No arbitrary Windows-volume scanning from the phone, bundled service token or fake provider success.

Primary references: reference/chromium-win32 (99 passing states, 390×844; all image hashes verified). Secondary: reference/chromium-win32-402x778 (matching iPhone 17 Pro content excluding documented 62pt top/34pt bottom system insets). DEVICE-CHECKS.md records what CI cannot establish.

## User-requested native improvements in build 25

The latest device feedback explicitly overrides PWA parity for full-content native Back gestures, active-tab return to root, shared Library+TMDB search (Glance remains current-watch-only), a compact expiring Undo toast, useful Glance menus, content-sized surprise and full-width expanded descriptions. Glass/press transitions use first-party SwiftUI effects. These changes await CI/UI/screenshot acceptance and physical timing checks; they are not accepted differences merely because the implementation exists.

The newest device screenshots also require hero art to scroll away before Episodes/Notes. Saved title, catalog and person backgrounds now attach to scrolling content. The tab lens follows a held finger across all five destinations and commits on release, cancelling outside the bar; reduced motion removes stretching/tilt/springs. Physical scrub/full-bleed/scrolled-background UI checks are included in build 25 and remain pending.

Explore now uses the system navigation bar with Back/search/Done instead of a hidden bar plus a second custom header. This is an intentional response to the native-navigation request. The public [content-pop gesture API](https://developer.apple.com/documentation/uikit/uinavigationcontroller/interactivecontentpopgesturerecognizer/) remains owned by UIKit; no private transition/delegate/KVC implementation is used. The episode control suppresses it only during active tracking. CI/device swipe checks remain required.


### Latest user-directed native changes, build29 pending

The user explicitly requests collection list/grid toggles and native navigation/gesture behavior beyond the original PWA. Settings and form fields remain forms. Shared controls now cover History, Home recent/upcoming, Glance, Files folders/scanner, episodes, catalog/discovery/filmography/search, Stats backlog and Trakt review. Library already has its source grid/list controls. These additions are not accepted parity evidence until the new CI/UI/phone checks pass. The shared hero preserves the synopsis lead beside the cover and expands only its overflow below, per the latest reference. The old all-size assertion that moved the entire synopsis below the cover has been replaced with stricter lead-position and continuation-bound checks.


## Explicit owner-requested design changes — prepared build35

The25Oct title reference replaces the old beside-poster synopsis: lowered identity on a darker hero, full-width opening synopsis below, retained opening lines with overflow-only More, and compact native poster/name/Back/Share while scrolled. Native Back replaces redundant Done on pushed pages; real editing sheets retain Done. Liquid Glass adds a blurred dominant-artwork background behind panels/controls/navigation, while foreground art remains sharp and accessibility can restore solid/reduced-motion presentation. These are requested differences from b43454e, not accidental parity drift. Source is prepared; all-size screenshots and native runtime acceptance are pending. The community route remains an undeployed additive backend change.

## Prepared native56 carousel adaptation (uncompiled)

The isolated next draft adds guarded5second rotation and previous/next/pause
with scene-restored title identity. A small top-corner native popover replaces
the web's hover/keyboard-only controls; card height, content, cover tap and
horizontal snapping stay unchanged. Automatic movement stays off with Reduce
Motion or VoiceOver instead of overriding those device settings. Rotation
stops offscreen, during page/tab navigation, a write, drag or open controls.
An ID/session-keyed task cancels when its list changes; no background polling
is added. Two policy tests and one actual automatic/pause/tab-return UI test
are prepared. This is not part of54/55runtime evidence or a passed comparison.

Native56also prepares the confirmed Glance copy/menu gap and touch-target
parity: source GlanceCard.svelte uses an absolutely positioned menu,17pt title,
3pt metadata margin and44pt targets around the smaller painted stepper. Native
previously let the menu impose44pt title-row height and exposed32–36pt targets.
The isolated draft overlays the extracted unchanged menu, preserves card height
and button paint sizes, adds44pt hit areas and makes the Home pending style
include its tinted background. Existing watch/cover/menu tests gain real target
bounds. Runtime and screenshot comparison remain pending;54images are unchanged.

## Owner-directed native57 navigation/material changes (uncompiled)

The owner explicitly replaces the custom web-like bottom capsule tracking with
SwiftUI's system TabView Liquid Glass bar. Five destinations and per-tab paths
remain. Tab labels/symbols/lens/touch tracking now follow native iOS behavior;
this is an authorized visual departure from web navigation. Root content
swipes coexist with short Glance one-watch swipes (long >=160pt pages).
Header identity/material fade over80pt with fixed toolbar slots. Information
retains its artwork-tinted translucency at both detents. Episode grid check
buttons sit over the bottom-right thumbnail and preserve44pt targets.

References: Apple's TabContent.accessibilityIdentifier, TabView,
TabBarMinimizeBehavior.never and containerBackground(.clear,for:.navigation).
No Swift compile/screenshots/physical smoothness acceptance yet.

##25October audit correction — native61runtime evidence, full suite pending

The earlier table's synchronous-cache statement is historical.61native tests now
verify off-main protected save and cold read with cancellation/owner fences.
All219native and17focused UI cases pass, including official native tab tracking,
body swipes, episode thumbnail checks, Notes targeting, import persistence and
Information content. Full primary/all-size/Release acceptance remains pending.
Owner54results remain in DEVICE-RESULTS-BUILD54.md. Physical header smoothness,
glass rendering, haptics, VoiceOver and large text still require device evidence.
62local draft aligns Catalog's header action with saved titles; no62runtime proof.
