# Historical progress through the native64 local draft

Superseded by root PROGRESS.md. Pending statements retain their original time and scope.

# Native TwilDiary progress

## Resume first

Current step: **10 — parity, stabilization and release hardening**. The app is
not declared finished. The complete older notes are preserved in
[ios/docs/BUILD-HISTORY-THROUGH-NATIVE54.md](ios/docs/BUILD-HISTORY-THROUGH-NATIVE54.md);
read specific historical sections only when needed. ROADMAP.md remains the
original10-step checklist. Owner subsequently prioritized building actual
features over repeating procedural gates.

At every session: read this file/ROADMAP, git status/log, current provider
results and actual artifacts; reconcile before editing. Notes and source test
counts never substitute for runtime evidence. No Mac/Xcode/Swift runtime is
available locally; Windows checks grammar/YAML/Bash/Python only.

## Native61complete — current deliverable;62next candidate

Official CM61**6ade36de4a72334e32e5107f** completed successfully for exact
**8c9514094e96498855b83034c52c4b4349af8fee**. Latest official
codemagic-ci-cd check121249082762is completed/success; verify-codemagic.py accepts
that exact SHA (older in-progress check is superseded by the newer official check).
Actual downloaded logs:219native,17focused,10early and53primary UI cases pass;
3layout tests pass on each iPhone17eand17ProMax. Simulator/device builds have
zero warnings; physical Release fixture/resource gate passed. This is full
Codemagic acceptance, not independent GitHub or real-phone performance proof.

Delivered **D:/Downloads/TwilDiary-native61-codemagic-passed.ipa**,5,726,283bytes,
SHA256**96eb75f475fdc1ff006c4e3acecbb94f50e6effd8d08d3b0f5ec86e29f24362e**.
Verified ZIP CRC, matching archived checksum, arm64Mach-O, iPhoneOS/min26/build61,
iPhone-only, encryption flag and absent fixture/TestSupport resources.
Release proof:ios/docs/releases/native61-codemagic-candidate.json.
Diagnostics D:/Downloads/TwilDiary_27_artifacts.zip:722,504,548bytes, ZIP CRC pass;
281logs/PNG/manifest attachments extracted into.local/codemagic61-diagnostics.
Eight unedited primary native screenshots and exact IDs/hashes/test scope are in
**ios/docs/screenshots/step-10/build-61-codemagic-passed**. Visually inspected
Home/Glance/title/header/grid/Information/import/Undo contact sheet; shared with
owner alongside the installable IPA. These are synthetic native fixtures.

61is not promoted toios-native:62contains the reviewed Intel-stage time budget
and new database/API preflight job. Keep GitHub54unchanged until coherent62
passes official CM. CM62**6ade49474a72334e32e515c7** checked out exact
**50134fc9addcc243434ee5721eb74ea1eec13f61** fromcodex/ios-ci-next.
Actual simulator/device compilation,219native,17focused and10early UI pass.
The Release resource gate confirms actual privacy-manifest packaging and fixture
exclusion. Primary/extra-phone UI and final artifacts are still running.
62adds Catalog header assertions plus
privacy resource packaging, API/runtime/query bounds and additive0016schema.
407backend/16CI-tool tests, typecheck and Worker build pass locally. No hosted
migration or deployment. Cold-process quota/bootstrap retry remains an open next
native scenario; do not label the whole audit finished.

## Native63draft — cold-process approved-import recovery

62is frozen on its running source.63adds an owned, read-only bootstrap when a
persisted approval survives but the first status/review fails. It waits for the
typed D1reset/provider Retry-After, checks current connection and exact review,
then hands off to the existing paced worker. No POST occurs before those checks.
Pause cancels bootstrap and clears approval; background preserves it; stale
session/review/account, fatal auth and six consecutive failed recovery attempts
stop without writing. Status transport preserves typed retry evidence too.
The Trakt screen shows a compact restoration/cooldown panel with no invented
percentage; the controller task continues across tabs. Debug-only cold-quota
fixture and a native UI case exercise wait/tab navigation/automatic recovery/Pause.

Eight new controller cases plus a URLProtocol case cover cold status/review quota,
Retry-After, explicit Pause, changed review/disconnection, late session callback,
bounded outage, background/foreground and expired Access session.228native/54UI
source inventory, all Swift grammar/YAML/Bash checks and16CI-tool cases pass.
**63has no macOS compilation/runtime proof yet.** Do not conflate tests written
with tests passed. Source f557580plus a stricter asynchronous-test completion
condition is reviewed; current architecture/parity/device documents now clearly
separate accepted61, running62and uncompiled63and mark obsolete notes as history.
63source**0c087e7** is published tocodex/ios-ci-next. CM63run
**6ade51214a72334e32e51821** was submitted on that branch/full regression workflow;
it is waiting for a machine and has no source-checkout/runtime evidence yet.
Do not push64to that branch before verifying63's actual source checkout.
Next: let62finish, verify its official result/resources/screenshots, and inspect
63's checkout/unit results.62must qualify completely before independent GHA.
Only the exact fully qualified source may move toios-native for independent GHA.

## Native64local draft — workspace page consistency

An actual isolated D1-driver reproduction reads titles, commits a fictional new
movie/watch, then reads events: the event refers to a title absent from the first
page. Fresh titles resolve it. This confirms a cross-section race during external
imports; it is not an observed real-account data loss or a whole-transaction claim.
The new backend characterization test passes. A native guard validates parent
title/episode ownership after unique IDs, then retries the full GET snapshot once
for this specific incompleteness. Persistent inconsistency/quota preserves the
last complete diary/cache. It never drops rows or retries a mutation.

Prepared one Core reference-integrity case and four URLProtocol cases: transient
race success, persistent bounded failure/cache preservation, quota during retry,
and sign-out during held retry.232native/54UI source cases plus69Core source cases;
Swift grammar/YAML/Bash/16tool checks pass.408backend tests pass. Local check
caught an over-narrow test projection cast; corrected it with runtime field
validation, reran that case and typecheck now has0errors/0warnings. No native64
macOS execution yet.64is local only;63's remote queued source stays0c087e7.

## Scope clarification and62database/workflow follow-up

Owner clarifies: **testing is exclusive to the native iOS app, its database/API,
Trakt data flow and build workflows**. Stop web UI/PWA walkthroughs. The temporary
local web UI tab was closed; prior local evidence is historical, not Swift UI
acceptance. Use native XCUITest artifacts for UI and disposable local D1/SQLite/
URLProtocol fixtures for data checks. Keep hosted library untouched during audit.

62follow-up captured actual native API SQL: latest Trakt review and movie progress
select a first row without LIMIT and sort all historical matches. Two regressions
failed before the fix with1,000reviews/600rewatches. All four ordered first-row
lookups now have explicit LIMIT1; additive0016adds recent-review/account-order
and active-movie partial indexes. Actual SQLite plans use the indexes without a
temporary sort;14targeted and all407Node tests pass. Wrangler applied0016only to
.local/audit58-d1.0typecheck errors/warnings. No hosted migration/deployment.
Generated0016schema snapshot matches the full schema; index changes preserve rows.

The62GitHub workflow now triggers for native API/schema/scheduler changes and
requires an Ubuntu Node24 database/API/shared-rule suite and Worker build before
macOS stable artifact generation. Pinned official setup-nodev7.1.0commit verified
through GitHub API. No deploy command, credential or hosted request is added.
YAML/Bash syntax and16CI-tool checks pass; workflow runtime waits for same-SHA CM
qualification and promotion.61remains frozen8c95140;62has not run on macOS yet.

Remaining import audit scenario: after a completely fresh process launches during
D1quota, status/review reads may fail before the checkpoint's run is loaded;
resumeApprovedApply currently requires a loaded matching run/status, so that
bootstrap does not own a retry timer. Existing in-process quota/background paths
are tested, and next foreground after recovery reloads it. Add a bounded,
checkpoint-fenced read-only bootstrap recovery test/fix after the current coherent
candidate; do not claim this cold-quota scenario proven or silently replay writes.

## Active61run and isolated62audit draft

**CM61run6ade36de4a72334e32e5107f** checked out exact
**8c9514094e96498855b83034c52c4b4349af8fee**. At the last read:219native
cases pass, including all six cold-cache tests; all17focused UI pass, including
both-direction root tabs/short card watch/Undo. Early regressions are running;
full53primary, extra-phone layouts and physical Release/artifact acceptance
are still pending. Keep that candidate frozen; do not rerun/promote prematurely.
The old GitHub stable ref remains54d59f55e with its recorded independent failure.

Independent local audit uses a disposable Workers/D1 copy, migrations0000–0015,
LOCAL_DIARY=1and fictional metadata configuration.30real watch/retry/Undo/
stale-write/Trash/restore contract requests pass. Another50read/validation/header/
paging/malformed-body/CSRF requests pass with byte-equivalent fixture data before
and after. No hosted requests/library changes. Private machine reports:
.local/native-api-contracts61.json and.local/extended-api61.json. Browser exercised
local Home/Glance and explicit watch/unwatch8→9→8; the short web Undo toast had
expired before its click, so that click is not counted as an Undo UI pass.

**62is a local draft, not the running61source.** Two new backend tests first
failed: legacy import accepts fractional/oversize runtimes; workspace emits a
REAL value incompatible with native Int.62enforces TMDB's1–1440whole-minute
bounds for legacy imports and serializes malformed existing runtime as unknown,
without modifying stored rows. Full405backend tests, web0errors/0warnings,
production build and3PWA cases pass. No hosted deploy/migration applied.

Release audit confirms delivered54IPA has no PrivacyInfo.xcprivacy.62adds only
the actual app-owned preferences/elapsed-time required reasons, explicit XcodeGen
resource inclusion and a built-bundle verification gate (16local CI-tool tests
pass). No empty collected-data assertion or App Store label completion claim.
Catalog still had a separate invisible Share slot beside Information;62reuses
the already-tested saved-title header action, removes the obsolete wrapper and
extends the retained-search case to verify forward/reverse catalog header states.
Windows Swift/YAML checks pass;62macOS typing/runtime/resource proof pending.

CI budget audit: GitHub54's8-case repair stage took12m37s on the pinned Intel
runner; the current17-case gate still has a15-minute stage cap.62sets35minutes
for that stage only, retaining individual XCTest deadlines. Do not spend a61
GitHub run on this stale budget; deliver a fully-passed CM61candidate if available,
then qualify62and promote62with its coherent workflow. No assertion was relaxed.

Next: let61complete all gates; download/verify artifacts and original screenshots.
Only full exact-SHA acceptance permits stable-branch promotion; prefer62after its same-SHA CM pass to include the audited Intel stage budget.
Commit62locally; push it to the candidate ref only when61has finished. Continue
remaining source/data-flow/accessibility audit without altering frozen61.

## Native61 — measured cold-path repair and native60 evidence

Current source61is prepared, not yet compiled. CM60run
**6ade2b024a72334e32e50d12**, exacte17189ebddd4392c87ac3d5fb33a44d00486b15d:
zero compiler warnings;213native pass;16of17focused UI cases pass. Remaining
failure is NativeScreensTests:141, left Glance-to-Library page swipe opens
Frieren. Recording confirms the cover push; symmetric negative-direction tap
suppression was missing in ProgressCard.61suppresses horizontal cover taps in
both directions, including non-markable cards. Assertions stay intact, adding
failure hierarchy/screenshots. Full primary/extra-phone/Release gates were not
reached on60; no IPA or stable promotion is inferred.

Native60archive D:/Downloads/TwilDiary_26_artifacts.zip is263,790,207bytes with
ZIP CRC pass, extracted .local/codemagic60-diagnostics. Original screenshots
from individually passed cases plus exact scope are in
**ios/docs/screenshots/step-10/build-60-focused**. Visually checked compact
header, episode tick placement, retained dark Information cards/blur, and import
progress. Phone animation quality remains unproved.

Actual native60scale diagnostic:10,000events synchronous cache load129.45ms,
index44.02ms.61moves cold encrypted file read/decode/validation to a detached
utility task; Keychain and generation-fenced publication stay on MainActor.
Launch performs memory-only resident lookup; network refresh awaits one cold
restore; sign-out/account/snapshot changes reject stale read results. Existing
sealed format/owner partition/size limits remain. Six added native regressions
cover executor yielding, cancellation, save/removal invalidation, offline launch
and account change;219native source cases, runtime pending.

Backend audit reproduced a partial activities response being accepted as a full
review snapshot. Require all six selected timestamps; new negative test failed
before the fix and passes afterward. Full **403backend cases**, web0errors/
0warnings typecheck, production build and3PWA tests pass.13CI-tool tests and
Windows grammar/workflow checks pass; these do not replace macOS acceptance.
No hosted migration/deploy applied. Quota/auth rollout checks remain open.

Exact next action: push61to codex/ios-ci-next and run the official complete CM
regression. Read actual failures/artifacts before another change. Do not promote
until complete same-SHA acceptance. GitHub ios-native remains54d59f55e.

## Native60 — follow-up from actual59 artifacts

CM59 **6ade213a4a72334e32e50a40**, c12f24bf33712905a545b394915642f0c009bd36:
0compiler warnings;213native tests pass;12of17focused cases pass. Five failures:
carousel controls open18Again instead of popover (recording/hierarchy confirmed),
returning root tab swipe also pushesFrieren (hierarchy confirmed), Share remains
inactive after scroll, episode overlay checkmark14pt from edge versus<8pt contract,
and native tab chrome still present on title search result. No unchanged rerun,
no promotion. Complete diagnostics downloaded D:/Downloads/TwilDiary_25_artifacts.zip
(308,602,905bytes, ZIP CRC pass), extracted .local/codemagic59-diagnostics.
Three original screenshots from individually passed cases plus precise scope:
ios/docs/screenshots/step-10/build-59-focused. Not a full passed build.

60candidate batches fixes: carousel controls become a higher-priority sibling of
the scroll track with a stable presentation owner; recognized page pans cancel
underlying cover-button touches; one native toolbar button owns Information/Share
crossfade and native activity sheet; remove root's forced-visible tab preference;
episode glyph32inside44target at thumbnail corner. Existing assertions retained;
carousel failure gets an explicit no-unwanted-title assertion and hierarchy.
Information screenshot still appeared too opaque despite functional pass; reduce
material masking and clear the NavigationStack container while retaining dark cards.

Backend audit: new keyset planning cursor preserves old offset/page checkpoints
once, then seeks byID. Migration0015is additive; presentation page stays compatible.
Two cursor/replay tests and full402backend cases pass; all local migrations through
0015pass. Added missing0014/0015Drizzle snapshots plus a no-schema-drift generator
regression, preventing future duplicate CREATE statements. No hosted deploy.

Exact next action: finish60self-review/docs/commit and run official CM full suite.
Windows checks are syntax only;60is not compiled/runtime accepted. Continue audit
while it runs; preserve candidate SHA and GitHub stable54branch.

## Native59 follow-up — actual58 failure and continued audit

CM58 **6ade1cf14a72334e32e50900**, exact sourcef3b9d33262b0e048cf9afa6fb5e3623d7370e9c8:
warning-free simulator build;212native tests executed,13new transfer tests all
pass; sole failure SessionTests.testTraktWireContractCarriesEveryExplicitDirectionChoice
supplies a temporary DiaryStore to the now-weak service. Retain the fixture owner
through the existing four wire assertions and add a store/controller release
regression. Native59source213tests; no59runtime evidence yet. Focused/full UI
not reached on58. No promotion/IPA acceptance.

Broader audit reproduced provider Retry-After loss at our API boundary; three
new tests first reproduced two failures then all passed after bounded header/date
handling. Full399Node tests and web0error/0warning typecheck pass. Wrangler
isolated D1 migrations0000–0014and2,000proposal trigger/count/order smoke pass;
local duration metadata does not establish hosted billing savings. Dependency
audit found Undici7.29.1 advisories in Miniflare; scoped patched7.30.1 override
now reports0vulnerabilities. Full npm run verify passes with patched tooling:399backend cases, web0errors/0warnings,
production build and3PWA runtime tests;13CI-tool checks pass.
Full audit ledger: ios/docs/AUDIT-2026-10-25.md.

Exact next action: push this59candidate and start official CM regression. Continue independent logic/performance audit while
it runs. No hosted migration/deploy yet; daily quota remains a rollout limitation.

## Active candidate and audit — native58

Owner authorized a rigorous whole-project audit on25October. First complete the
coherent import/quota repair, then audit remaining native UI/data/auth/cache,
backend invariants/query costs and release flows. Track evidence and regressions;
do not claim every line or phone behavior tested from source inspection alone.

| Track | Exact source | Current evidence |
| --- | --- | --- |
| GitHub ios-native, native54 | d59f55e5fa574382b067477f6b4fb079690507a8 | CM54complete pass; GHA40192486938attempt2warning-free compile/188native pass but two focused UI failures. No unchanged rerun. Owner phone results recorded. |
| Complete Codemagic55 | ae2cfdcccbe58fbd2f353abbbfabb4fa67b59766 | Full regression passed; verified IPA download still pending. |
| Codemagic57 | abc62cca039f3acda4388b001e7bc53851ca11ca | CM6ade0cac4a72334e32e5044d:0compiler warnings/197native pass; focused gate failed10cases, primarily old custom tab-home selectors after adopting native TabView. No promotion. |
| Local native58, codex/ios-phone-polish | this commit | Candidate:212native/53primary/17focused source cases. Native tab tests use public UITabBar labels; approved bulk job persists across tabs and restarts, paced safe cooldown/reconciliation, progress and rounded actions. No macOS58evidence yet. |

The opened D1 metrics confirm12.23Mrows read/36.56kwritten inLast24hours;
three repeated count scans alone6.70Mreads and next-change selection2.30M.
Additive migration0014uses transactionally maintained review buckets and ordered
partial indexes; explicit LIMIT1on ready selection. Full396Node tests pass;
final web typecheck has0errors/0warnings; production build and13CI-tool tests pass.
Windows Swift grammar/YAML checks pass; macOS compilation/runtime remains unverified.
Detailed evidence and rollout order: ios/docs/TRAKT-IMPORT-RELIABILITY.md.
No hosted migration/deploy applied; current daily allowance is exhausted. Direct
Wrangler analytics401, authenticated dashboard works. No hosted writes in audit.

Exact next action: push this reviewed candidate only and start one complete
Codemagic regression; inspect actual
failures and screenshots while continuing independent audit. Do not promote an
incomplete candidate or call a partial gate stable.

Native source is **Amit29533/TwilDiary**, /ios. Original web /preview source
and user-directed native changes are authoritative. The old TwilDiary-iOS repo
is preserved historical source, not the active build or proof. No push to main,
force push, signing setup or new backend deploy is part of current work.

Only a complete official Codemagic regression success for an exact SHA may
promote that SHA to ios-native. GitHub then independently runs the complete
suite before stable IPA publication. The differently named device-diagnostic
workflow cannot satisfy promotion. Candidate source on GitHub is needed for
Codemagic checkout; it is not stable publication. Preserve each running candidate SHA. Do not promote58under54/55acceptance.

## Last complete acceptance — native54

Codemagic54 **6adde71f4a72334e32e4fa14**:
https://codemagic.io/app/6adcc927390bc3069c9e5490/build/6adde71f4a72334e32e4fa14

- Zero simulator/device/compiler/tool warnings and zero failures.
-188native tests,8focused UI,10early UI, all51primary UI, and3layout cases
  on each extra phone (iPhone17e/17ProMax) pass.
- Actual unsigned physical Release/resource gate passes. IPA independently
  verified: hash, ZIP CRC, arm64/iPhoneOS/minOS26/build54, system-encryption
  flag and no fixture/TestSupport JSON. No provider uptime/phone FPS claim.
- Official same-SHA check was verified before fast-forwarding ios-native.
  Independent GitHub54 **40192486938**:
  https://github.com/Amit29533/TwilDiary/actions/runs/40192486938
  Candidate-proof passes. Attempt1failed simulator test compilation: RandomPickScopeTests saw both old Core.SampleWorkspace and new TestSupport.SampleWorkspace, although Core source no longer contains that helper and clean CM54/55compile. Actual log restored pre-split native cache9471189867. Invalidating the13matching old native cache entries prevents fallback to another pre-split module; rerun failed macOS job on unchanged54source after that environment repair (attempt2queued/running). This is not yet an
  independently green stable release. Read its latest jobs before changing it.

Delivered: **D:/Downloads/TwilDiary-native54-codemagic-passed.ipa**
(5,616,221bytes), SHA256
71c8597fdc218ff2370148cbf733d66376304ef2987293486eac6e92437a9798.
Metadata/hash beside it; committed proof:
ios/docs/releases/native54-codemagic-candidate.json.
Original diagnostics archive: D:/Downloads/TwilDiary_21_artifacts.zip
(654,763,214bytes, CRC pass), logs/screens extracted to .local/codemagic54-diagnostics.

Six original primary PNGs, original attachment IDs/test/device/hash scope:
ios/docs/screenshots/step-10/build-54-codemagic-passed.
Visually inspected .local/native54-passed-overview.png and Home/Glance
side-by-side references. Matching402x778 usable canvases use declared scale3
and top62/bottom34OS-only insets, with no stretching. Font weights/metrics,
small spacing/card padding and requested native controls differ; no claim of
pixel-identical parity. Comparison outputs remain .local/native54-*-web-comparison.png.

Owner asked which IPA to try; directed them explicitly to native54, with History/Explore Back, slow/reverse compact-header scroll and the visible watched-episode Log rewatch action. Owner has now returned T01–T33 results; see DEVICE-RESULTS-BUILD54.md. Header/tab gestures/episode-grid/Notes animation/toast/glass fixes are open; data flows broadly pass. Native53diagnostic remains available but is superseded for this check. Earlier native40 owner feedback confirms
Information sentiments/dismissal, incoming-switch persistence, Notes targeting,
watch/Undo, keyboard-safe search, tab scrub and offline navigation.

## Native55 — complete Codemagic pass; hold promotion during54GitHub

CM55 **6addf45f4a72334e32e4fd86**:
https://codemagic.io/app/6adcc927390bc3069c9e5490/build/6addf45f4a72334e32e4fd86
Actual checkoutae2cfdc was read in its source log. Startup proof:
.local/codemagic55-started.jpg. This source has194native/51primary/8focused
cases. All194native cases, including five cache concurrency tests and the store sign-out interleaving, now pass with warning-free simulator compilation; all51primary,8focused,10early,3per extra phone and Release/final0warning gates now pass. Official exact-SHA check accepted; artifact verification remains next.

Production changes: WorkspaceCache validation/JSON/AES preparation moves into a
utility detached task with immutable Sendable inputs. Cancellation reaches the
worker; newer sync/async saves and removeAll invalidate its ticket before the
atomic MainActor protected-file commit. The store rechecks session/snapshot
following the await and treats cache failure as optional. Same format/owner
scope/bounds/protection/backup exclusion; no offline write outbox.

Six new deterministic cache/store cases cover off-main work, removal/sign-out,
newer-save wins, cancellation preserving the previous cache and over-limit
preservation. Tests use temporary paths/injected keys. Scale test prints total
async latency separately from sync load/index. Cold load, Keychain lookup and
final protected commit intentionally remain synchronous. Prior native52M2
10k-watch measurements: save66.66ms/load56.28ms/index25.47ms. No55speed claim
until actual macOS measurements. Native55M2 diagnostic now reports10k events: sync save139.71ms, async total77.56ms, sync load75.51ms, index45.12ms (1k9.75/9.80/8.45/4.10ms). These are cross-run-noisy diagnostics; the gated test proves off-main preparation, not a phone speedup/FPS. All13CI-tool checks pass locally.

## Native56 — separate local carousel and card-parity batch

Direct audit confirmed web ContinueCarousel.svelte has guarded5second rotation,
wrap previous/next, pause and retained identity, while native Home had only
snapping/manual swipe. Prepared ContinueWatchingCarousel retains card geometry,
cover/watch actions and root gesture exclusion. It adds visibility/scene/tab/
path/write/drag/motion/VoiceOver/open-controls guards, interaction cooldown,
scene identity/pause restoration and an ID/session-keyed cancelled task.

Self-review caught fixture scene-state leaking selected cards across separate UI cases. DEBUG preview now seeds a deterministic paused first card once per view, preserving same-case tab returns; only the dedicated --ui-automatic-carousel case seeds real default rotation and asserts Pause is initially available, actual advance, and six seconds of no movement after pause. Release behavior/preferences are untouched. This prevents unrelated slow UI assertions/screenshots from racing a5second timer without removing automatic-behavior coverage.

A small rounded top-corner popover exposes previous/next/pause rather than the
web's hover/focus-only controls. This deliberate native adaptation is documented
in IOS-PARITY.md. Two policy tests and one actual automatic/pause/tab-return
UI test are added; Home search explicitly suppresses automatic movement while open; the new case joins the focused gate (10cases: all old8plus carousel and the changed Glance hit-target/cover/menu case)
so failures stop before the long suite. Source196native/52primary; local
.local/validate56.py passes, **no56Swift compile/runtime/screenshots yet**.

Direct54web/native screenshot comparison also confirmed the Glance name/time gap: a44pt Menu occupied the title HStack height although the web absolutely positions its menu. Prepared56extracts that menu into an overlay, retains every existing action/Notes target, reserves title space, and matches the web17pt name/3pt copy gap. The web also uses44pt stepper/Home hit areas around32–36pt painted buttons. Native controls were only32–36pt;56adds44pt content shapes without enlarging the card row, fixes Home pending opacity by keeping tint inside the disabled-aware press style, and adds real hit-frame assertions to the existing toast/cover/menu UI case. No watch/menu/state rules changed. These layout/input changes are uncompiled56, absent from the owner's54IPA, and require fresh screenshots/full regression.

## Owner phone checklist

Owner requested the complete device test list. Wrote ios/docs/DEVICE-TEST-BUILD54.md
and D:/Downloads/TwilDiary-native54-iPhone-checklist.md with41numbered checks,
prioritized old UI issues, watch/rewatch/Undo/date/season rules, all screens,
reviewed/automatic Trakt distinction and real-phone offline/accessibility/performance.
Explicitly excludes55cache and56carousel features from54expectations. T01–T33 results are now recorded in DEVICE-RESULTS-BUILD54.md; T34–T41 remain pending; do not treat sending a checklist as a pass. Reviewed sync checks refer to actual incoming/outgoing proposals, not an invented global one-way/two-way switch; Undo timing states the8second VoiceOver allowance.

## GitHub54 cache repair / native56future protection

GHA54attempt1fails with ambiguous SampleWorkspace.make and two downstream key-path inference errors; actual notes identify a removed Core symbol plus the new Support symbol. Source is unchanged from fully passed clean CM54. Saved .local/github54-{failed,all}.log and exact restored cache list. Clear only rebuildable native-macos26-X64-xcode26.6 caches on ios-native (not diary/hosted data), then rerun the failed54job once. This is a changed cache environment, not retrying an unexplained failure. Future56restore/save keys now also include the Package.swift graph hash before the source hash, and fallback is restricted to the same graph; it cannot reuse the old target/resource layout. Current55CMref remains frozen.

The changed Glance toast/cover/menu case now joins the focused gate alongside carousel, giving10focused cases while preserving all old8. Catch card-input regressions before the long suite.

## Native57 — owner phone fixes prepared, not compiled

Owner's T01–T33 pass/partial/fail results are recorded verbatim in meaning in
DEVICE-RESULTS-BUILD54.md. Both10.34s/8.87s clips were extracted and visually
inspected locally. They confirm binary toolbar replacement and unstable custom
bar tracking. Screen evidence confirms watch controls below episode artwork,
opaque large Information presentation and a separate material header stripe.

Prepared source: native SwiftUI TabView/TabContent identifiers and .never bar
minimization; removed custom lens/zero-distance gesture and global hidden bar.
Root paging attaches to the real window with active-root/path/modal ownership;
long card swipes page while short one-watch swipes retain their existing action.
Horizontal carousels, text inputs, native tabs and sliders remain excluded.
Title/catalog identity and material crossfade over80scroll points with retained
toolbar slots; no binary background visibility change. Notes/Files/episode focus
scroll uses reduced-motion-aware .smooth. Episode grid watch controls overlay
thumbnail bottom-right; layout toggle shares the Episodes row. Undo uses a44pt
capsule up to330pt wide, retaining44pt action targets and expiry/hold semantics.
Information clears NavigationStack/sheet fill and retains blurred title artwork
at both detents with black sentiment cards. Glass backgrounds are preblurred once
before bounded cache insertion; removed duplicate root/full-screen material work
and PageHeader's flat material stripe. No quantified phone performance claim.

Includes unshipped56carousel/card work and accepted55cache preparation. Build56
was never compiled or distributed. Native57local syntax197native/52primary and
13tool tests pass;16focused cases now exercise native tabs, actual body swipes,
tracking, grid overlays, Notes and Information before the full suite. Swift type/
runtime and new screenshots pending. No promotion or new phone IPA yet.

## Exact next actions

1. Run the coherent57candidate on Codemagic only; inspect compiler/197native, then16focused cases, complete regression and actual screenshots. Keep GitHub stable unchanged until exact-SHA CM success. Preserve55artifacts if downloading.
   Read54GitHub focused/full/extra-phone evidence independently. Do not retry
   unchanged failures or promote a diagnostic-only success.
2. If55fullgreen, download/verify current artifacts and measurements, then
   hold it while54GitHub is collecting independent evidence; do not cancel54by pushing55. Promote only after the active GitHub run resolves, or batch its accepted changes into the later fully-qualified56source. A red55requires inspecting concrete logs first.
3. Continue56self-review while55runs. New56carousel UI test resolves its identified container independent of UIKit accessibility element type, rejects nil selection and also requires exactly one fully visible/hittable cover after movement. Keep56off the candidate ref until ready;
   then run its own complete Codemagic validation. Verify real automatic/pause,
   restoration, card/root gestures and current screenshots; no hidden assertion
   removal or timeouts-until-green.
4. Finish remaining visual/privacy/accessibility/performance and source parity
   gaps. Preserve source/run identity in every screenshot and IPA delivered.

## Remaining / blocked evidence

- Full independent GitHub54acceptance, then55/56complete provider runs.
- Owner phone: compact-header threshold/reverse scroll, bar/gesture timing,
  glass contrast/transparency, haptics, VoiceOver and large Dynamic Type.
  CI cannot establish tactile smoothness or battery use.
- Cold protected cache reads, workspace indexing/first projections and remote
  poster downsampling remain performance work. Existing NSCache/bounded card,
  discovery/person/community caches and projection memoization already exist;
  blanket uncached-image claims were false. No broad actor rewrite.
- PRIVACY-AUDIT.md records actual app-only preferences, local logo-tap uptime,
  fixed-backend/Trakt/TMDB flows and unverified provider/log retention. Required-
  reason manifest packaging/final labels and optional all-window app-switcher
  cover remain open. Do not claim D1-backed diary data is zero collection.
- Native54Home/Glance/other screen comparisons are not pixel-identical.
  Source references:80primary390x844 states and secondary402x778 canvases.
  See IOS-PARITY.md, QUALITY-AND-REMAINING.md, REVIEW-T24-T37.md and DEVICE-CHECKS.md.
- Backend incoming46is deployed,38focused/391complete Node tests passed before
  that authorized rollout. Scheduler3150a352-0013-4151-a93a-00d6266b9b46;
  main Worker1dc0eced-83ac-4312-8d40-73aa6124cba5. A preserved active manual
  review fences automatic imports; do not cancel/apply it just to manufacture
  a timing result. Real completed-watch import latency and active Free10msCPU/
  D1 usage are unproved. The earlier3ms was the paused idle path only.
- Unique single local watch within6h links a Trakt play preserving local date;
  ambiguous matches require review. Existing tests cover cursor quarantine,
  generation/account/title/event fences and revoked/Trash replay protection.

## Build/test and safety

XcodeGen ios/project.yml; Swift6strict concurrency/iOS26+ for owner's iOS27.
CI pins Xcode26.6, iOS26.5 iPhone17Pro,17e,17ProMax; GHA macos-26-intel,
CM mac_mini_m2. No hand-written pbxproj. No third-party Swift dependencies.
Use ios/scripts/ci.sh and codemagic.yaml; only macOS runs Swift.

Windows tools: C:/Program Files/GitHub CLI/gh.exe; python .local/validate56.py
for current10-case source; earlier55uses validate48.py/8cases. The unchanged
TraktSignIn parser limitation matches compiled47bytes; grammar is not typing.
Use python -B ios/tools/test_verify_codemagic.py, test_verify_release_resources.py,
test_run_bounded.py and test_verify_build_log.py (13cases total).
PIL/ffmpeg runtime: C:/Users/Amit Singh/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe.

Cua browser working, existing tab1=CM55, tab2=GitHub, tab3=passed53diagnostic.
Normal authenticated artifact link + download event works; downloadMedia times
out/unauthenticated URL401. A large archive's event may time out yet complete
normally in D:/Downloads: inspect the actual named file before retrying. Never
extract browser cookies/tokens. Re-read cua documentation after compaction.

No secrets, SQL backups, .dev.vars or .local/incoming-secrets in commits/output.
Hosted data stays read-only in current native work; local/fixtures for tests.
No new deployments, migrations, review destruction, signing or App Store actions.
Commit format step N: <what>. Update this current file before meaningful commits.
