# Native quality and remaining work — 25 October 2026

This checkpoint reviews native candidate47 (`8c9f163`) and the separate,
unpromoted review draft (`5064856` plus the cache-size repair). It is a focused
correctness/performance/release review of store, transport, persistence,
projections, shared caching, navigation and CI, combined with T24–T37 claim
verification. It is not a fresh runtime test of every screen or a real-device
performance certification. Windows has not compiled Swift.

## Native54 completed;55candidate running

Complete CM54 d59f55e passed0warnings/188native/8focused/10early/51primary
and3layout cases on each extra phone. Original passed screenshots and their
scope are in screenshots/step-10/build-54-codemagic-passed. Its verified
arm64iPhoneOS IPA is delivered. Independent GitHub54/run40192486938 is running
on that exact promoted SHA; no stable-publication claim yet. CM55 is now testing
only the detached cache-preparation batch, sourceae2cfdc. Native56carousel is a
separate local draft. PRIVACY-AUDIT.md records actual required-reason API and
data-flow findings without claiming zero collection or a packaged manifest.

## Historical checkpoint — native54 running; native55 isolated draft

At 11:41 UTC, complete Codemagic54/run6adde71f4a72334e32e4fa14 is testing
frozen d59f55e. Compilation is warning-free,188native tests, all8focused UI and
all10early navigation/progress checks pass. The repaired visible episode
rewatch action retains real Undo and exactly8original History watches. The
51primary/all-phone/Release/final artifact gates are not yet accepted. The
stable branch remains8c9f163; its independent GitHub47 regression failed.

Native53's separate physical-device diagnostic passed zero-warning Release
compilation and actual fixture exclusion; its verified test IPA is available
to the owner. It is not a complete regression or stable release. Full53 failed
only the intermittent hidden rewatch gesture, which54 replaces with the
visible details action rather than another timing-only retry.

| Reviewed concern | Evidence now | Remaining |
| --- | --- | --- |
| HTTP status/quota/retry/session isolation | Native54's188tests pass, including JSON403,304, sibling quota ordering, expired reset, cancellation, bounded GET retry and no automatic POST retry. | Same-source full/independent provider acceptance. |
| Explicit episode rewatch/Undo | Native54 focused case passes visible action, Undo, original checked state and exact8-history count. | Full suite and physical interaction feedback. |
| Persistent Library, sign-in policy, release fixture/tool metadata | Native54 relaunch test passes; native53 actual physical bundle excludes Core workspace/test-support JSON and compiles without metadata warnings. | Real provider2FA and final full54 Release artifact. |
| Cache write responsiveness | Native55 local draft moves validation/JSON/AES into a detached worker and fences cancellation/newer saves/sign-out. Six new interleaving/boundary tests; total194native source cases. | Swift compilation/runtime and new scale measurements. Cold reads and atomic protected commit remain synchronous. |
| Images, indexing, first Home/Stats projection | Existing bounded caches/memoization verified; native52 measured10k-event index25.47ms and cache load56.28ms. | Profile cold paths and artwork decode on phone; no blanket uncached-image claim. |
| Privacy/accessibility/device polish | Existing chart bucket labels/actions, reduced-motion/transparency paths and owner40feedback. | Required-reason manifest audit, optional all-window privacy cover, VoiceOver/large text and owner53header/swipe feedback. |
| Incoming Trakt | Prior backend46hardening38focused/391full tests and deployed source recorded in PROGRESS. | Owner manual review still fences automatic imports; real import latency/Free-plan CPU not proven. Never discard the review to manufacture a result. |

The following entries retain earlier evidence and hypotheses chronologically.
They do not override this current checkpoint or imply an unfinished feature is
absent merely because its old acceptance checkbox is unchecked.

## Historical acceptance updates

Codemagic47 fully passed (173native/49primary/all-phone/zero warnings), but
independent GitHub47 failed its retained-search content-Back case, so no stable
IPA was published. Codemagic48 passed184native and5/6focused; the new episode
rewatch menu failed.49 compiled with zero warnings, then failed1/184native:
parallel quota responses could turn the awaited title error into cancellation,
suppressing the quota message.50 repairs that race with deterministic gated
responses and two additional quota regressions. Its186native/sixfocused/51full
and all-phone results are still pending. Review hardening is candidate-only;
origin/ios-native remains the exact47 source. Historical evidence below retains
its original checkpoint scope; it is not current all-step acceptance.

Native50 passed the repaired quota ordering but failed a fixed-date parsing
expectation and a repeated-cursor request-count assertion; the runner then
stalled after test results and was cancelled.51 freezes the test clock, isolates
URLProtocol cases/cancellation, retains strict cursor bounds with diagnostics,
and bounds the unit process. It also prepares test-only resource separation and
a stronger built-bundle gate. Native187/full51/all-phone/Release acceptance is
pending; these are candidate changes, not a new stable release.

Native51 passed187native and all6focused checks (including the explicit episode
rewatch/Undo/History case), with one Core metadata-tool warning found in the final summary.9of10early checks passed;
one settings History content swipe began then cancelled. The original unedited
passing-case screenshots and scope manifest are in
screenshots/step-10/build-51-passed-cases.52 narrows the settings test stroke to
the longer, previously passed baseline, adds that case to the focused gate and
prepares a1,000/10,000-watch cache/index diagnostic. No stable publication or
full51/all-phone/Release acceptance. The release-resource separation is compiled
and unit-tested in51; its actual physical Release resource gate is still pending.

Native52 passed188native, all7focused and9/10early cases. Settings Back/swipes
passed twice. Explore cancelled the shorter232.67pt native content pan; the
longer318.33pt baseline stroke passed on settings.53 uses the long plain-text
stroke for all content-return checks, including synopsis below the title poster,
and adds Explore to the focused gate. It conditionally links first-party
AppIntents for the exact Core framework warning, and rejects tool warnings
immediately after compilation. Physical phone diagnostic and full regression
remain separate; no stable promotion.

The52M2 diagnostic measured10,000watches: protected save66.66ms, load56.28ms,
index25.47ms (1,000:8.59/3.63/5.20ms). This supports prioritizing off-main cache
I/O while retaining owner/session/sign-out fences. It does not establish phone
frame rate or justify a rushed concurrency rewrite during UI stabilization.

## Earlier native47 checkpoint evidence

* Codemagic47 `6addaa674a72334e32e4ed86` checked out exact
  `8c9f16376389a4b8d162b7cd7b12e96d4fffb7b6`. Native173 units, the4 focused
  stability cases, and all10 early progress/navigation cases pass. The focused
  cases cover Glass compact identity, filmography heading/control alignment,
  retained search/Back, and episode/range/movie Undo. Device Release compilation
  reached success; the full primary/all-phone/final warning gates are pending
  at this checkpoint. This is not overall acceptance.
* GitHub46 `40166839268` is the older `66d625e` diagnostic run. It failed its
  early gate and continues collecting full evidence under the old workflow.
  Do not call it stable or confuse it with candidate47.
* Backend hardening38 focused and391 complete Node tests passed before the
  authorized deployment. This review has not changed server code and has not
  rerun unchanged server tests just to increase the test count.
* Candidate/stable separation is implemented in47. GitHub promotion requires
  the official complete Codemagic check for the exact SHA, then independent
  full GitHub acceptance. A candidate compilation/IPA alone cannot promote.

## Confirmed correctness and release gaps

| Priority | Finding and scope | Status / required next proof |
| --- | --- | --- |
| P1 | Full acceptance across both providers is not yet established. Current focused repairs passing does not prove complete screen/layout acceptance. | Finish47 full49 UI plus both3-case extra-phone suites, inspect screenshots, then same-SHA GitHub validation. Physical scroll/interactive navigation remains separate. |
| P2 | Baseline `DiaryAPI` treats JSON403/304 as expired login and forgets D1 quota reset state. Repeated automatic reads can continue during a known outage. | Prepared typed-status and shared circuit-breaker changes with mock transport regressions on the private review branch. Not compiled/run in47 and not promoted. |
| P2 | An uncertain normal watch and a rewatch share one pending-operation key in baseline code, despite different user intent. | Prepared separate stable intent keys and an idempotency regression in the review draft; movie rewatch already exists. Explicit episode rewatch action is also drafted, not accepted. |
| P2 | Protected-cache writer accepts files larger than the reader's50MiB bound, reports successful caching, and can replace a previously loadable snapshot with one rejected after restart. | Newly prepared shared read/write bound, including encrypted-file overhead, with exact-limit/oversize/preserve-old-file regression. It does not change live diary data. Local syntax passes; new XCTest still needs macOS. |
| P2 | The release resource gate is incomplete: Core's test `workspace.json` is a resource of the production package target, while the gate only rejects `reference-workspace.json`, `catalog-*`, and `trakt-*`. | Confirmed in source and in the downloaded43 IPA at `TwilDiaryCore_TwilDiaryCore.bundle/workspace.json`. It is synthetic test data, with no demonstrated production fallback path; it is still unnecessary release payload. Move test support/resources out of the production target and make the bundle gate reject this name before final release. Do not claim all test fixtures are absent based on the current gate. |
| P2 | Sign-in web navigation policy, persistent Library layout/sort/filters and Codemagic tool pinning need hardening. | Changes and tests prepared on the private review branch.47 intentionally excludes new features. Real provider2FA/popups need a phone check after the policy is built. |
| P3 | Privacy manifest/API-use audit, app-switcher cover and full real VoiceOver/large Dynamic Type audit remain open. | Accessibility labels and selectable chart buckets already exist; an Audio Graph descriptor is an enhancement. A privacy cover must include presented sheets and not break sign-in. No placeholder completion checkboxes. |

## Performance: verified improvements and remaining costs

Already present and covered by current tests:

* Workspace pages decode in detached tasks, with cancellation and session
  fencing before publication. Failed/overlapping pages cannot replace a good
  workspace with partial or duplicate identities.
* Shared card requests coalesce, cache per title/revision/season/day and
  invalidate only affected inputs. The card cache is bounded at128 entries;
  discovery at16, person metadata and community information at32 each.
* Home/Stats projections memoize by workspace/day and relevant calendar,
  zone/range/year. In47's1000-event simulator diagnostic, the cold combined
  projections took72.08ms; the warm pair averaged0.02ms. That test includes
  correctness assertions and is not a phone frame-rate or battery measurement.
* History parses timestamps before ordering and pre-resolves episode lookups.
  Draft fields retain unsaved edits and detect conflicting record versions.
* Provider scores batch bounded requests, retain already-fetched values during
  transient outages and clear per-session state. Discovery can present cached
  recommendations during refresh. No claim of instant provider responses.

Remaining performance work, in order:

1. `ProtectedWorkspaceCache` JSON/AES/file reads and atomic writes currently
   execute on the main actor. Move these behind an asynchronous serialized
   cache interface after the stability baseline, retaining owner/session and
   generation checks so a late save cannot restore signed-out data. Measure
   cold load and save using realistic large snapshots before/after.
2. Workspace indexing and first Home/Stats projections still run synchronously.
   Every accepted edit fetches a full paginated snapshot and rebuilds indices.
   Warm memoization does not remove this cold cost. Profile large event/episode
   sets and invalidation frequency before adding incremental publication.
3. Production artwork uses `AsyncImage`; the app has no explicit remote
   downsampling pipeline. Demo artwork already uses `NSCache`, so the claim
   that every image is uncached is false. Profile repeated poster/backdrop
   decoding and memory before replacing the image layer.
4. Real-device frame pacing, material rendering, touch/haptic timing and battery
   behavior remain in DEVICE-CHECKS.md. CI timing cannot prove these.

## Product work versus validation work

The main views and flows exist: Home, Library/Queue/Trash, saved and catalog
titles/seasons/episodes, Explore/search/cast, Glance, Stats/History,
Files/scanner review, settings/provider setup, exports, reviewed Trakt sync,
Information sentiments and incoming-watch settings. Do not describe unchecked
historical roadmap acceptance boxes as if all those views still need building.

Still required before calling the app finished:

* Finish automated acceptance and inspect current, correctly attributed
  screenshots for every phone size/theme/state in scope.
* Verify on the owner's phone that compact-header crossing/reversing scroll,
  root swipes versus card/carousel gestures, destination-owned bar transitions,
  Information material and expanded episode grids match the latest requests.
* Finish the prepared correctness/release batch and validate it on Codemagic
  before promoting any feature to GitHub.
* Prove real incoming-watch idempotence and observed latency/CPU/D1 usage on
  the Free setup. The preserved manual review currently fences automatic work;
  the measured3ms was that paused path, not a normal enabled import. Never
  cancel the owner's review just to manufacture a performance result.
* Complete the source-of-truth parity comparison, documented intentional native
  differences, accessibility/privacy/release checklist and final regression.

Maintainability is serviceable but can improve: `DiaryStore`, `TitleDetailView`
and shared `Components` combine substantial responsibilities, and many long
view expressions make failures harder to inspect. Extract cohesive parts while
touching those areas, after correctness gates pass; a broad formatting/actor
rewrite during stability validation would increase the review surface without
proving better performance.

One checked apparent discrepancy is intentional: Home's planned cards use
personal ratings in both the current web source (`HomeSections`/`TitleCard`)
and native `personalRating:true`; the Library uses selected community ratings.
Do not change that behavior based solely on a pattern search.
