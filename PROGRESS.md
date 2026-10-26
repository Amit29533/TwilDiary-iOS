# Native TwilDiary progress

## Resume first

Current step: **10 — stabilization, parity and release hardening**. Not finished.
Latest hosted change: **26 October 2026, 09:41 IST — backend rollout completed**.
From the new canonical repository's `develop` track, deployed frozen backend
`50134fc9addcc243434ee5721eb74ea1eec13f61` as Worker version
`d21c2b88-a874-46fa-8dc4-61798d8544d8`. Applied exactly D1 migrations 0014–0016
after a fresh Time Travel bookmark, private full export and successful local
restore/rehearsal. Post-deployment export proves every original row/column in 26
application tables is preserved; integrity/FKs pass and review buckets are exact.
Authenticated `/api/session`, review and incoming GETs pass; unauthenticated
session is denied 403. Review remains 735 applied / 1474 pending / 1466 safe / 1 link,
and incoming remains enabled but paused behind that same unfinished review.
No apply/skip, scheduler redeploy, Access change, paid upgrade or iOS build.
Hosted read-only SQL samples: buckets 8 rows, next-ready 1 row, seek page 40 rows;
expected indexes/no temporary sorts. These are individual SQL costs, not a full
bulk-import/active-Cron budget certification. Dashboard 00:00–04:16 UTC shows
approximately 98k reads / 13k writes for the account's only D1 database, including
rollout overhead. Initial read-only diagnostics consumed 12207 rows, 0 writes.
Full-day sustained cost, active 10ms CPU and native64 runtime remain open.
See ios/docs/releases/backend62-production-rollout.json and BACKEND-ROLLOUT.md.
Private exports/bookmarks/logs remain ignored in.local/cloudflare-rollout-20261026.
Earlier "not deployed" notes below describe preparation before this rollout.

Audit scope: **native iOS UI, its database/API/Trakt data flow and CI workflows**.
Do not restart web/PWA UI walkthroughs. Tests use synthetic native fixtures,
URLProtocol or disposable local D1/SQLite. Current hosted library stays untouched.

Read ROADMAP.md, this file, git status/log and actual CI/provider results before
editing. Source tests and notes never replace executed evidence. Historical
progress is preserved in ios/docs/BUILD-HISTORY-THROUGH-NATIVE54.md and
BUILD-HISTORY-NATIVE55-64.md; old pending statements there are historical.

Windows has no Mac/Xcode/Swift compiler. Swift compiles and runs only in macOS
CI. XcodeGen generates the project; no hand-written pbxproj. Swift6/Observation,
iOS26+ for owner's iOS27, no third-party Swift packages. Toolchain: Xcode26.6,
iOS26.5 iPhone17Pro/17e/17ProMax. CM M2candidate; GHA macos-26-intel independent.


## Canonical repository after consolidation26October2026

The owner explicitly requested all native development, backend and pipelines move
into **Amit29533/TwilDiary-iOS**. This checkout is now the canonical complete
project; local pathC:/Users/Amit Singh/Documents/ChatGPT/Track Everything/TwilDiary-iOS.
The imported source is originalTwilDiaryc14333f(full native64draft/backend prep).
Merge7dd0eff has the exact same tree3c7cbe7e7250e5c7e2348ad9892037c70be56def,
with both original and destination history preserved. Main holds the complete snapshot; `develop` is the active **unreleased**
track. Neither is a newly accepted stable build. Existing source and failed
CI evidence remain honest; no new native build/deployment is started here.

Native62latest fully passed CMartifact downloaded from6ade49474a72334e32e515c7:
actualIPA5,719,316bytes, build62,iPhoneOS,privacy/no-fixtures/ZIPCRC verified,
SHA2563ba1075f327170553344e94cf73de199e778c7c619029b855042c53b6f8d1cd2.
Full724,086,122byteartifact ZIPCRC and matching internalIPAchecksum verified.
Actual logs prove68Core,219native,17focused,10early,53primary,3layouts each extra
phone,0nativewarnings. Imported GitHub **prerelease** tag native62-codemagic
points at its exact50134fcsource; assets includeIPA,checksum,provenance and282
selected full logs/screenshots/manifests. Original GitHub62fourfocused failures
still disqualify stable acceptance. Native64 remains uncompiled;63failure retained.
Eight original62screenshots committed atios/docs/screenshots/step-10/build-62-codemagic-passed.

Fresh independent target checkout npmci/audit0,409NodeAPI/database cases,27Python
release-tool cases,0error/0warningtypecheck,scheduledWorkertsc and Workerbuild
pass locally. Nodebuild prints the existing NO_COLOR/FORCE_COLOR environment
notice; no macOS/production-budget claim follows. No hostedDBtestrows used.

RootREADME/CODEMAGIC now explain standalone native/backend builds, main versus
qualifiedios-native and same-repositoryofficialCMcheck policy. Original readmes
and oldnativepreview/authnotes are preserved in docs/WEB-BACKEND-README.md and
ios/docs/legacy-repository. Full source inventory and verification are in
ios/docs/migration/source-inventory.json andios/docs/REPOSITORY-MIGRATION.md.
New repository.yml cheaply verifies main/develop/backend/API/tools without hosted access;
ios.yml retains full native gates and codemagic.yaml remains manual only.
Import uses[skip ci] to honor the next-build hold and avoid consuming Mac minutes.

Owner completed GitHubemail/sudoverification and repository access. Created
Codemagicdestinationapp6ade764b746d1dee285e9ce8forAmit29533/TwilDiary-iOSin the
existingTwilDiaryteam. Originalapp6adcc927390bc3069c9e5490retained for history. Rootcodemagic.yaml
detected on main and develop; develop is selected with Start your first build
shown. No new native job. Destination Linux run40236806826 on b17de16 passed
409backend tests,27Python tests, zero-error/warning typecheck and Workerbuild.
No new token/signing/Cloudflaresecret,billingchange or nativebuild started.
Existing CloudflareWorkers/D1/Access/appbundleID/baseURL are unchanged; do not
create a second hosted library or deploy merely because the repo moved.

## Current source/provider matrix — 26 October2026 IST

- **61 complete Codemagic / delivered IPA:** source8c9514094e96498855b83034c52c4b4349af8fee,
  run6ade36de4a72334e32e5107f, official check121249082762. Downloaded logs prove
  219native,17focused,10early,53primary UI;3layout cases each extra phone;
  68Core cases, zero build warnings. Actual physical arm64 IPA/ZIP/checksum/resources
  verified. D:/Downloads/TwilDiary-native61-codemagic-passed.ipa,
  SHA25696eb75f475fdc1ff006c4e3acecbb94f50e6effd8d08d3b0f5ec86e29f24362e.
  Original screenshots:ios/docs/screenshots/step-10/build-61-codemagic-passed;
  scope/hash/provenance JSON retained and images visually inspected/shared.
- **62 complete official Codemagic; independent GitHub failed:** exact
  50134fc9addcc243434ee5721eb74ea1eec13f61, CM6ade49474a72334e32e515c7,
  official completed/success check121268303837. verify-codemagic.py accepts it.
  Prior live log inspection proved219native/17focused/10early, device Release,
  privacy manifest in actual bundle and no fixtures. Complete official provider
  pass is verified; final screenshot/IPA archive download remains pending.
  Only this exact SHA fast-forwardedios-native. **GHA40228034161failed** at the
  focused iOS gate. Candidate-proof/backend-contracts pass; downloaded Ubuntu logs
  prove407tests, typecheck0errors/0warnings and successful Worker build. Intel
  simulator compilation/219native units pass,0buildwarnings. Four focused failures:
  carousel advance timeout; Explore and persisted-Library setup could not terminate
  the app; rewatch Undo showed9watches instead of8. Later UI/layout/device publication
  skipped. Full failed logs/UnitTests/RepairGate downloaded to.local/github62-final;
  no stable GitHub IPA published, no unchanged rerun. CMpass does not erase this
  independent failure. Root causes not yet established.
- **63 failed Codemagic candidate:** source0c087e72745e44a39cb4439ea1036f3ee26c0a71,
  CM6ade51214a72334e32e51821, official final check121280525245failure at
  20:21:05UTC25October. Older initialcheck121268338393remainsin_progress;
  always fetch all same-SHA checks and use latestofficialID, not a fixed initialID.
  Owner supplied final diagnostic:0buildwarnings,228native tests pass (21transfer,
  78session); cold-quota UI fails atNativeScreensTests.swift191finding
  trakt-pause-restoration. Extra-phone layouts skipped. No promotion/retry.
  Its final full screenshot/log archive is not downloaded; do not invent remaining
  case counts. The candidate refcodex/ios-ci-nextstays0c087e7.
- **64 local draft:** eb0f3db plus evidence/document reconciliation oncodex/ios-phone-polish.236native/54primary and69Core
  source cases; Swift grammar/YAML/Bash and16CI-tool cases pass.408backend tests
  and0-error/0-warning typecheck pass. Not compiled/run on macOS. Do not publish
  it over63's candidate ref while that evidence is still being collected.

Browser control works again during the repository consolidation; GitHub CLI works. The earlier disabled-browser notes below are historical. CM62artifact
and full63hierarchy/attachment inspection need browser access. The owner pasted
63failure summary, sufficient to isolate the failed control but not full hierarchy. Do not
extract cookies/tokens or bypass that boundary. Browser ID2; CM62tab7/CM63tab8
were markedhandoff. Re-read CUA docs after compaction; get fresh tab inventory
if stale. Preserve any owner tabs. A downloaded artifact event can timeout while
its file still finishes inD:/Downloads; inspect the file before retrying.

## Implemented and actually tested through61

- First-party SwiftUI TabView bar, stable per-tab paths, both-direction body
  swipes/no wrapping with short Glance watch gesture/Undo ownership preserved.
- Shared single native saved-title header action: crossfade Information/Share,
  centered identity and fixed toolbar slots. Episode grid tick overlays thumbnail
  bottom-right with44pt touch target. Native keyboard-safe Back/search/Notes.
- Retained bulk Trakt controller survives tabs; only approved runID persists.
  2,000-change regression, typed cooldown/Retry-After/D1reset, GETread-back before
  further write, bounded6recovery failures, explicit Pause and background/resume.
  No blind POST transport replay. Global counts/progress and rounded controls.
- Protected owner-scoped AES-GCM cache: off-main save preparation/cold read,
  cancellation/session/snapshot/cache generation fences. Keychain and short atomic
  commit stay on UI actor. Cold-load/restoration and stale callback tests pass.
  Index/projection still on MainActor; no physical FPS/battery claim.
- Actual full UI covers Home carousel/controls, Library filters/sorting/Queue/
  Trash/restore, title/range/movie/history/Undo, spoilers/ratings/notes, discovery/
  cast, Stats/date/unknown history, settings/files/scanner, Information states,
  per-card pending/category reuse, native root/navigation/empty/error states.
  Physical motion/material/accessibility remains separately unverified.

##62qualified changes and pending hosted data rollout

- Catalog reuses the saved-title one-button header; focused search-return
  assertions now include forward/reverse Share/Information ownership.
- PrivacyInfo.xcprivacy explicitly packaged; CA92.1app-only preferences and
  35F9.1in-app elapsed time. Built-bundle verifier checks reasons and excludes
  fixtures/TestSupport. No empty collected-data declaration; final privacy labels
  and provider/log retention still need review.
- Legacy runtime import now accepts whole1–1440minutes/null; malformed existing
  rows projectunknown without rewriting storage. Negative regressions reproduced
  acceptance/serialization beforefix.
- Actual SQL captured unbounded ordered latest review/movie-watch reads.
  Four first-row queries nowLIMIT1;0016ordered/partial indexes avoid full history
  sorting in real SQLite plans (1,000reviews/600rewatches). Local WranglerD1pass.
-0014incremental review bucket triggers/counters/indexes remove repeated COUNT
  scans after every apply;0015durable planning IDcursor replaces continuingOFFSET
  work and upgrades old checkpoints after one compatibility read. Atomicity,
  rollback/replay/600apply/2kchange/backfill/query-plan tests pass locally.
- GHA now requires same-SHA CM pass plus Ubuntu native API/database contracts
  before macOSartifact publication.17focused-case Intel budget35min is based on
  actual8-case12m37s/17-case M2~13m30s; individual test deadlines unchanged.

Before the26October09:41ISTrollout, no0014–0016hosted migration/deployment had
been applied. Current hosted evidence is at the top of this file. Dashboard rolling24h
showed12.23Mreads,36.56kwrites/34.98kqueries. Five hot scans explained11.41Mreads;
3counts6.70M. Rolling24h is not a current UTC/account quota measurement.
FreeD1allowance5Mreads/100kwrites/account/day,00UTC=05:30IST reset. No fixed number
of imports/day can be claimed. Direct Wrangler analytics401; authenticated dashboard
provided the evidence. Do not infer all Cloudflare auth is broken from that.

Previously authorized incoming46deployment is preserved: scheduler
3150a352-0013-4151-a93a-00d6266b9b46, mainWorker1dc0eced-83ac-4312-8d40-73aa6124cba5.
An unfinished manual review fences automatic incoming; do not cancel/apply it to
manufacture latency evidence. User permits linking exactly one unlinked local
sameepisode/movie watch within6h, retaining local date; ambiguous matchesreview.
Active Free10msCPU/real-watch latency/new hosted quota cost remain unproven;
earlier3ms was paused idle only. Before authorized rollout: validated backup,
quota/auth/schema checks, additive migrations before dependent code, preserve
owner review and verify actual metrics. No new hosted writes just for tests.

##63cold-process approved-import recovery — runtime pending

Persisted approval existed but resume required already-loaded status/review, so a
cold launch duringD1quota owned no retry timer.63adds a retained GET-only bootstrap:
wait typed reset/providerRetry-After, check current connection/exact reviewed run
and approval after every await, then use the existing paced worker. Six failed
recovery attempts/auth/account/review changes stop; Pause clearsapproval and cancels
restoration; background preservesapproval. Status transport keeps typed errors.
UI shows restoration/cooldown/Pause without fabricatedcounts/percentage before
review loads. Debug-only coldquota fixture starts a20srefusal; actual UI test
checks nofakeprogress, tabcontinuation, automaticrecovery andPause.

Eight controller cases plusURLProtocolcase cover status/reviewquota, Retry-After,
Pause, mismatchedreview/disconnection, latecallback, boundedoutage, background/
foreground and expiredAccess. Self-reviewed syntax only until CM63results.

##64workspace consistency — reproduced API race, native runtime pending

An isolated real D1-driver/API characterization reads titles, commits fictional
external movie/watch, then reads events:1watch refers to missing earlierparent.
Fresh titles resolve it. This proves a possible interleaving, not hosted data loss.
64validates parent titles and episode ownership after uniqueIDs; one full GET
snapshot retry on typed incompleteness. Persistent badpages/quota preserve last
complete diary/cache; no rowdrop/mutationretry. Corecase plus4URLProtocoltests
cover reference validity, transient success, bounded persistentfailure/cache,
quota and signoutduringheldretry.408backendtests/checkpass; macOS64stillpending.
This protects references, not a transactionally versioned snapshot of every value.

Additional local verification captures the actual incoming-status and minute-lease
SQL with1,000completed reviews, both no-active and one-active review. All four
query plans use the existingtrakt_one_active_runpartial index; no historical-run
scan and zero provider calls while not due/manual-review-paused. Three targeted
query cases pass and fresh typecheck0errors/0warnings. No production change was
needed for that hypothesis; this is a test-only follow-up, not hosted-cost proof.
The last full backend suite was408cases; the added case has targeted execution.

Read-only Cloudflare verification26OctoberIST: D1info succeeds,27tables,
12,349,440bytes, rolling24h11,863,309reads/36,364writes (23,780readqueries,
10,077writequeries). Sorted Workerdeploymentmetadata confirms100% version
1dc0eced-83ac-4312-8d40-73aa6124cba5 from25October06:09UTC. Remote migration-list
query rejects with Cloudflare7500dailyreadlimit; no migrations/deploy applied.
Metadata/auth works; live query quota still blocks rollout verification. Told
owner actual reset05:30IST26October. Rolling24hmetrics are not exact UTCdayusage.

64also fences Pause/cancellation immediately after a held recovery GET. Previously
apply/scan checked Pause before that await but could begin one extraPOST after it.
New held-read regressions assert no additional apply after Pause/background and
no scan-step after Pause/cancellation; background approval still resumes only after
foreground read-back. This source-confirmed race is repaired in the local draft,
not claimed as native runtime evidence. Four added cases bring native source236.
Swift grammar/YAML/Bash checks pass; no backend rerun needed for this native-only
follow-up.63remains frozen on its separate running source. Matching already-complete runs
are also accepted via GET without replaying a lost final receipt, clearing the
persisted approval and showing the confirmed completed state. Its regression
requires zero apply requests.

## Owner feedback hold before the next build

Owner tested the previous fully passed Codemagic build: native62 (50134fc / CM
6ade49474a72334e32e515c7). They report issues but have not described them yet;
they will prepare the complete bug chart and asked us to continue the existing
tests meanwhile. **Do not
start native64 while this feedback is pending. Notify the owner before starting
the next build.** Native63was already running before this request;62independent
GHA subsequently failed as above. No new build has been started since the owner asked.

Owner asked whether cooldown/stopping fixes are live. Replied precisely:62has
app-side bulk/tab/progress/cooldown handling;63cold-start recovery awaited tests at that reply; its later UI failure is above;
Cloudflare hot-query fixes are tested code but0014–0016are not deployed. A genuine
D1daily quota cannot be bypassed. No claim that hosted usage is already fixed.

## Exact next work

1. GHA62andCM63failed; retain exact scoped evidence. GHA62diagnostics downloaded
   to.local/github62-final; inspect the four actual focused failures before fixes.
   CM63full hierarchy/artifacts still need browser access. No
   retry or native64start until owner bug chart is incorporated; notify first.
2. Do not rerun failed candidates unchanged or promote a newer draft.
   Prepared64adds explicit restoration-panel accessibility child containment,
   waits/assertsPauseexistence+enabled+hittable, and prints hierarchy/screenshot
   on failure. This mirrors the existing working importpanel, but root-cause/
   runtime acceptance remains unproven until macOS. Add the failed case to the
  18case focused gate so it runs before spending time on later suites. Per-case
   assertions/deadlines are not relaxed. No64build started.
3. Finish isolated native data/logic/quality checks and current parity evidence.
   Avoid broad unmeasured refactors or new features while stability is under test.
4. Remaining real-phone checks: slow/reversing compactheader, barphysics/root/
   controlgestures, glassdetents/contrast, largeDynamicType/VoiceOver, coldlock/
   offline/accountswitch, large-library responsiveness/battery/haptics.


## Deployment preparation completed26October — no hosted actions

Owner authorized doing deployment prep now and explicitly requested Free-tier
account/read-budget care. Frozen backend source50134fc matches the tested server
files in the current draft; no untested native64code enters the package. New
`ios/tools/prepare-d1-rollout.py` pins fullSHA/latest official CMsuccess, hashes
migrations/config/lockfile and backend trees, archives exactGit source and restores
an optional private SQL export only into memory. Full ledger/schema/integrity/FK
checks, original row/column digests, exact aggregate counts and partial0014–0016
rollout support; no Wrangler/network/hosted operation in the tool. Fails on drift,
unknown/holed ledger, altered rows or counter mismatch. Private row values never
appear in reports/errors.11newtests; all27Pythonrelease/tooltests pass.

Actual disposable Wrangler4.151.3D1/workerd rehearsal: baseline0000–0013seeded
with2,000proposals(600applied,skipped,uncertain,conflict), watches/Undo receipts,
notes/favorite/Queue/incoming settings/acknowledgements. Its SQLexport restored;
actual0014–0016upgrade and post-export exactly match in-memory rehearsal. All26
original app tables/rows preserved;27after,2watchrows,2,000proposals,counters exact,
FK/integrityOK. Read-onlypre/postflight SQL added/tested, including corruption
reporting and unchanged rows. The first synthetic seed's dependency order and
unsupported exportpersist flag were corrected locally before this successful
run; no hosted attempt or claim followed from those local setup failures.

Private package: .local/backend-rollout-native62-20261026/package/source.tar,
SHA256fe1491379246aaf4b396b7cf5d3f6957f56255118c256950a96f4e51ee407bda.
Exact source extracted, npmci/audit0vulnerabilities, Workerbuild and Wrangler
**dry-run** pass. One generated bareDrizzleimport/no-side-effects bundler warning
retained; do not claim zeroWorkerbundlewarnings.150generated build files hashed,
builtpayload archivedworker-build.tarSHA256
029e0b8af35f4df63809dafef8f9c66170e965e92c463235737c39ee90102de3.
Public provenance:ios/docs/releases/backend62-deployment-preparation.json.
Runbook:ios/docs/BACKEND-ROLLOUT.md (freshbackup/restore/target/quota checks,
0014→0015→0016beforemainWorker,keep-varsforAccesssettings,unchangedCron,
read-onlyactive-reviewchecks,code-firstrollbackkeepingadditiveschema).

All deployment-prep test D1reads/writes are local:0hostedrows. Last hosted SQL
verification was7500exhaustedreadquota, not proof of a recovered budget. No more
hosted quota SQL probes, export, migration or deployment in this prep. Engineering
target2.5Maccountreads/day,50kwrites/day(50%headroom);initial hosted diagnostic
phase capped50kadditional measuredreads, accountUTCday+othertraffic/DDL cost
must be checked. These are acceptance targets, not new runtime globalmeters.
Existing incoming5,000workunits estimate writes, **not** D1reads/globalusage.
Production savings/actualactive10msCPU margins remain unverified after rollout;
pausedidle3ms and localqueryplans do not qualify. No paidupgrade/CI run started.

## Build/test/resume commands and safety

Repo C:/Users/Amit Singh/Documents/ChatGPT/Track Everything/TwilDiary-iOS.
Usegit status/log-20, gh run list --branchios-native, gh run view/log-failed,
gh run download. AddC:/Program Files/GitHub CLItoPATHifneeded. Node24.21installed.
Windows:python.local/validate58.py (grammar only); python-munittestdiscover-sios/tools
-p'test_*.py'; npmtest/API SQLitefixtures; npmruncheck; npmrunbuildforWorker.
Do not run PWA/browserUItests. Mac:ios/scripts/xcodegen.sh thenios/scripts/ci.sh
stages via codemagic.yaml/.github/workflows/ios.yml. Official complete CM
check must match exactSHA; verify-codemagic.py before fast-forwardstablebranch.

No secrets/.dev.vars/SQLbackups/privatevideos/.localin commits/output. No mainpush,
force-push, unapprovedirreversibledatachange, signing/AppStore action. Update this
file before meaningfulstep10commits. User requests autonomouswork; proceed with
reversible authorized fixes and tests, report material results concisely.
