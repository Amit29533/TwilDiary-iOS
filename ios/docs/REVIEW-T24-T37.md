# Review pass 2: claim verification

Verified 25 October 2026 against `Amit29533/TwilDiary`, native baseline
`66d625e24e7c2c3d954965113432ecc80114b6b3`, plus the local review-fix draft.
The supplied review examined `Amit29533/TwilDiary-iOS/main` at `5d9cc2e`.
Those are different source revisions and repositories. Its example code and
grep preflight are suggestions, not evidence of current behavior or permission
to change the delivery workflow.

“Prepared” below means source and regression tests exist locally. It does not
mean macOS compilation, runtime acceptance, deployment, or promotion to the
stable track. The owner has asked to stabilize existing regressions first;
these new changes are parked on a separate local review branch meanwhile.

| Claim | Current finding | Action / evidence |
| --- | --- | --- |
| T24: reappearance destroys drafts/season choice | Already addressed in this source. | `TitleDetailView` seeds editors once with `initializedEditor`, preserves `chosenSeason`, and uses versioned draft fields. Existing Notes/cast-return UI coverage and owner Notes checks remain. The proposed `app.tabBars` test does not apply to this app's custom bar, which is hidden on detail screens. |
| T25: Home/History sort timestamp strings | Already addressed in the cited production paths. | Core `HistoryQuery` parses dates before sorting with stable identity; `HomeOverview` uses that projection. This does not assert every date comparison elsewhere in the app is converted. |
| T26: JSON 403 and 304 cause sign-out | Confirmed. | Prepared distinct `notModified`, application JSON rejection, and Access HTML/redirect handling, with URLProtocol tests. Conditional ETag refresh itself remains separate work. |
| T27: quota errors do not stop repeated reads | Confirmed. | Prepared a shared, observable transport circuit breaker using server reset time or UTC midnight; suppress automatic reads/resume refresh, retain manual retry, and prevent older in-flight responses clearing a newer block. Reset time appears quietly in Settings, respecting the owner's request to remove intrusive status banners. |
| T28: images are never cached and all posters decode synchronously | Overstated; a performance gap remains. | `DemoArtwork` already has an `NSCache`; the fixture-image path is DEBUG-only. Production remote artwork uses `AsyncImage`, without an app-owned downsampling pipeline. Remote cache/decode performance still needs measurement before replacing it. No image-pipeline completion claim. |
| T29: offline handling / safe GET retry | Partly confirmed. | Encrypted local cache, foreground coalescing and owner-tested offline navigation already exist. Prepared friendly transport errors, cancellation propagation and one bounded retry only for a dropped GET connection; never automatic writes or doubled full timeouts. No `NWPathMonitor` or new offline banner added. |
| T30: sign-in web navigation is unrestricted | Confirmed. | Prepared HTTPS/blank-document navigation policy and same-view handling of allowed provider popups. Trusted-cookie and session-finish checks stay intact. Real 2FA/provider behavior remains a phone check. |
| T31: Library preferences are transient/stringly typed | Confirmed. | Prepared persistent layout/genre-row/typed sort preferences and scene-restored filters using the existing `LibraryQuery.Sort`; relaunch UI regression added. |
| T32: replace History search with `.searchable` | Design suggestion, not a demonstrated defect. | Current History distinguishes shared Library/TMDB search from local watch-history filtering. It has date presets, selected state, clear filters and matching empty copy. Preserve the owner's consistent-search requirement rather than replacing controls just to satisfy a grep. |
| T33: chart has no accessible labels/actions | Incorrect as a blanket claim. | The visual plot is accessibility-hidden, while native per-bucket buttons expose date description, duration, watch count, selection and drill-down. Audio Graph support and a real VoiceOver pass remain enhancements. |
| T34: no app-switcher privacy cover | Confirmed optional privacy gap. | Still open. A robust implementation must also cover presented sheets without disrupting login, Control Center or native navigation; a root-only overlay is insufficient proof. |
| T35: no rewatches | Incorrect for movies; missing explicit episode action. | Movie rewatch, operation identity and recovery tests already exist. Prepared watched-episode context action, Undo regression and distinct stable pending keys for normal-watch versus rewatch intent. |
| T36: unpinned tools / missing release metadata | Mixed. | GitHub already pins XcodeGen by SHA256 and Release warnings are errors. Codemagic used its preinstalled/Homebrew version: prepared one shared, checksum-verified universal vendor helper. Prepared system-only encryption metadata and a generated-bundle test. Privacy manifest/data-use audit remains open. No signing or App Store submission changes. |
| T37: History/Library lack row views and index | Already substantially addressed. | `HistoryRow`, `LibraryTitleRow` and pre-resolved History episode identities exist. Extracting the remaining Backlog helper is optional cleanup, not evidence of a current crash or quadratic History rendering. |

## Validation checkpoint

Local Swift syntax, YAML and Bash checks pass for the draft; Windows has not
type-checked or run Swift. There are 183 native XCTest methods and 51 primary
UI methods in the draft inventory, not 183/51 runtime passes.

Baseline native46 Codemagic run `6add98d74a72334e32e4eaad` compiled with zero
warnings and passed 173 native unit tests, but failed the full UI acceptance:
the Glass compact-header test stops before scrolling, and the filmography
heading/control alignment assertion fails. Its all-phone layout acceptance is
also red. GitHub run `40166839268` remains an independent diagnostic run, with
an early progress/navigation failure. Neither is a stable build.

The compact-header log specifically shows no swipe between opening the title
and requesting `title-share`: the newly always-mounted, opacity-hidden title
identity can still exist in XCTest's tree. Tests must wait for the visible
compact state, not use existence of that retained node as proof of scrolling.
Keep the assertions for share availability, header containment, and return
navigation; do not remove them or label a failed run accepted.


## Current native54 review update

The native53 diagnostic IPA compiles for the physical iPhone with zero warnings
and passes the stronger fixture/test-support exclusion gate. Native53 simulator
compilation is also warning-free,188native cases pass, and7of8focused UI cases
pass. The episode rewatch long press intermittently activates the row's ordinary
summary tap instead.54 therefore exposes a rounded Log rewatch action in the
expanded watched-episode details and removes the competing hidden gesture.
Its unchanged Undo/original-watch/History-count requirements still need54runtime
proof. No stable release is claimed. The source/provenance/hash of the owner
phone-test artifact are recorded in releases/native53-device-diagnostic.json.

Native54 update:188native tests and all8focused UI checks passed, including the
new visible rewatch action, real Undo and exactly8original History watches. All
10early navigation/progress checks also passed. The51primary/all-phone/Release
gates remain running; this is not complete54acceptance or stable promotion.

Native55 is a separate unpromoted cache-preparation draft with six additional
interleaving/boundary tests, not a rewrite of the proven networking or watch
rules. Local syntax checks do not establish Swift type checking or performance.
