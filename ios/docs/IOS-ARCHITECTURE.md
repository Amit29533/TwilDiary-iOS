# Native architecture

The native application is a SwiftUI client of the existing Cloudflare Worker and D1 API. Swift 6 strict concurrency, Observation and iOS 26+ are used; the user confirmed an iOS 27 phone. XcodeGen generates the project in macOS CI. There are no third-party Swift dependencies. CryptoKit protects read snapshots; Foundation, Security, SwiftUI, Charts and UIKit provide the other runtime capabilities.

## Current boundaries after the complete native61 Codemagic pass

The five-tab bar is first-party SwiftUI TabView with minimization disabled;
UIKit owns native tracking and push/pop. Root body swipes are a separate bounded
recognizer that yields to horizontal controls/Glance watch gestures. The older
custom capsule/lens descriptions below are historical.

Cold protected reads and save preparation now perform file authentication,
JSON and AES-GCM work in utility detached tasks. Keychain lookup and the short
atomic protected-file commit stay on the main actor. Session, snapshot and
cache generations fence publication after cancellation/account changes; no
synchronous disk read occurs in store initialization.219native tests include
executor/race/format/large-snapshot coverage; this is not physical FPS proof.
Incidental saved-cache notices stay in Settings, while actionable write recovery
and real errors retain their explicit UI.

The retained Trakt controller owns approved bulk work across tabs; only the
approved review ID is persisted in preferences. Tokens remain in Keychain/server
storage. Warm quota/read-back/background behavior passes61.63adds bounded cold
bootstrap GET recovery before any write, with fresh connection/review/approval
checks; its macOS acceptance is pending. The existing Worker+D1 remains the
single backend.0014–0016are additive local-tested candidates, not deployed changes.

Codemagic is the candidate track. Only an official complete same-SHA pass may
advance toios-native; GitHub independently runs native checks, API/database
contracts and device packaging. New62privacy resource and backend GHA gate are
separately tracked; a written test is never described as a passed execution.

DiaryStore is main-actor isolated. URLSession uses a restricted HTTPS backend and explicit Access credentials stored in Keychain. Sign-in uses a non-persistent WKWebView only for the existing Cloudflare login flow; all product screens are native SwiftUI. The database-independent session endpoint validates login before loading complete paginated workspace snapshots. Partial reloads never replace a valid snapshot. Session/request generations discard late responses after sign-out and older refreshes. Mutation identities are retained in memory for uncertain retries; version checks and server Undo receipts preserve concurrency semantics. The current web requires reconnecting to save, so no offline write is claimed successful or silently queued; a write outbox is not a parity requirement.

ProtectedWorkspaceCache saves complete owner-scoped snapshots using AES-GCM and a random 256-bit device-only Keychain key. Files use complete iOS data protection, atomic replacement and backup exclusion. The cache partition hashes the backend plus issuer/subject from an already saved Access session (falling back to a token digest); these claims are never used as authentication. The server remains the only authorization authority. Expired/missing credentials cannot open cached UI. The cached-state notice includes the last confirmed refresh time; a failed network read preserves this snapshot. Corrupt, wrong-key or wrong-owner data fails closed without partial publication. Sign-out removes the snapshots and credentials. No tokens are written into the cache. Tests use temporary directories and injected keys, never the real app cache or owner library.

### Prepared native55 cache write boundary (macOS validation pending)

The measured native52 10,000-watch synchronous save took66.66ms on its M2
simulator. The next isolated draft moves identity validation, JSON encoding and
AES-GCM sealing into a utility detached task. Immutable Workspace, date, scope,
size bound and CryptoKit key are its only inputs; no store or UI state crosses
the boundary. Apple documents SymmetricKey as Sendable:
[CryptoKit SymmetricKey](https://developer.apple.com/documentation/cryptokit/symmetrickey).

Cancellation reaches the worker. After preparation, the main-actor cache checks
both task cancellation and its write-generation ticket before atomically
committing the protected file, with no suspension between that check and disk
replacement. A newer sync/async save or removeAll invalidates an older ticket.
The store also checks its session and snapshot revision after awaiting cache
work, so sign-out cannot publish stale warnings or restore old data. Cache
failure remains optional read-cache failure, rather than turning a confirmed
network snapshot into a failed mutation.

This intentionally retains synchronous cold-load/key lookup and the short
protected-file commit on the main actor. It does not claim all disk I/O is
asynchronous. Encrypted format, owner authentication, bounds, backup exclusion
and the no-offline-write policy remain unchanged. Gated interleaving tests cover
off-main preparation, sign-out removal, newer-save wins, cancellation preserving
the prior cache and over-limit preservation; the scale diagnostic separately
prints total asynchronous latency, synchronous load and index cost. Native55
performance/runtime acceptance remains pending until macOS runs them.

TwilDiaryCore contains Codable API projections, calendar/progress calculations and catalog identities. Movie and TV provider IDs remain distinct. Public TMDB/Trakt ratings never fall back to personal ratings. Catalog screens review before import, and production requests use authenticated server routes.

AppRouter owns tab selection and independent navigation paths. The custom capsule navigation, opaque headers and Lucide vector PDF assets are derived from the web source. Assets are cached with NSCache. SwiftUI AsyncImage handles remote images. Remaining-time shadow is limited to the remaining-time text. Undo is an overlay above the capsule and does not change the content safe-area height. Series progress pieces follow episode identities; movies keep continuous progress. Range planning and authenticated transactions are implemented; full mutation UI coverage remains on the parity checklist.

Debug --ui-testing selects an isolated synthetic workspace and provider fixtures. Release builds cannot activate that fixture mode. The web reference uses a disposable local D1 instance on port 5193 and blocks provider/hosted requests. Existing web files and deployment workflows are unchanged.

CI builds simulator/test targets, runs core and session tests and XCUITests, exports retained screenshot attachments and builds an unsigned physical-device IPA. Native visual parity and offline/provider management work are explicitly tracked in PROGRESS.md; this is not a finished parity claim.

## Native provider review and title history (build 10, awaiting CI)

TraktServicing separates the existing backend API from an isolated Debug fixture provider. TraktController owns review filtering/paging, decimal sync mode, scan/step/pause, explicit per-item local/Trakt/apply/skip choices, safe batches, cancellation and server retry cooldowns. Source fields/counts stay authoritative; conflicts are never folded into Apply all ready changes. The API contract is unchanged, and demo export exclusion continues to be enforced by the existing server. The fixture provider makes no HTTP calls and is compiled out of Release builds.

Trakt authentication keeps the registered HTTPS backend callback and server-owned PKCE flow. An ephemeral auth-only WKWebView seeds the existing Access cookie for the same private hostname, POSTs the existing connect endpoint and keeps its HttpOnly state cookie through the provider callback. Only auth.trakt.tv is accepted as the initial provider destination. The fixed callback return is intercepted before the product page loads. An external-browser sign-in option supports providers that reject embedded browsers; returning to the native app rechecks server connection status. ASWebAuthenticationSession cannot be seeded with the app's private Access cookie and the existing callback does not redirect to an app scheme, so it is not substituted without a backend callback change. No backend addition or deployment is required for the implemented path. Real-device/provider sign-in remains explicitly unverified by synthetic tests.

Title progress planning is pure TwilDiaryCore logic. A slider preserves existing prefix watch dates, revokes every active suffix rewatch, adds only missing aired episodes, and does not touch other seasons. A command keeps per-request operation IDs across uncertain responses, retains partial Undo receipts, and refuses a different target count while a previous command is unconfirmed. Confirmed status reset/completion supersedes older pending intents. Movie logging distinguishes first watches from rewatches and preserves older viewings when removing the latest. Native date selection resolves a past day to local noon; today uses the current instant, matching the web.

Export uses the same schemaVersion/titles/episodes/events/locations/skippedEpisodeIds envelope as the web, with complete archived/revoked history and location evidence fields. It uses the native file exporter only after a tap; credentials are not part of the export model. Provider credential editing remains PC/server-only, matching the hosted mobile web boundary.


## Stats and collection regression (core/unit tests passed in 40035195084)

StatsOverview is a Codable projection of unchanged web diaryStats. UTC surrogates represent local calendar days for DST-safe periods/comparisons/streaks; future local days are excluded without rejecting later instants on today. A reproducible Node generator produces 17 web golden cases covering every period, leap/month clamps, DST, empty data, missing runtimes/catalogue, future/invalid/undated watches, rewatches, revoked events and Trash. The chart retains zero buckets and year month boundaries. Fresh navigation starts Today; the original five range choices synchronize overlapping calendar periods only.

CollectionRequest freezes up to 60 distinct reviewed title versions. Ordinary collection edits use the existing single atomic bulk endpoint; Planned/Completed use the existing progress transaction with retained operation IDs, metadata preparation and a retryable Undo receipt. LibraryQuery follows web normalization, independent Queue/favorite/status/availability/disk semantics, public score sorting and source genre shelf ordering/unclassified behavior.

Only DEBUG --ui-testing --ui-mutations enables FixtureDiaryBackend. It owns synthetic in-memory data and has no network API. Every collection item/version/state is validated before publishing a change. Unsupported fixture requests fail explicitly, never reaching URLSession or the hosted backend. It now supports collection/Trash, ordinary title patches, watch/progress/Undo transactions, metadata preparation, catalog/manual import and scanner review through isolated request handlers; pure/URLProtocol/local-backend evidence remains complementary. Release code cannot enable this fixture. The native Empty Trash action adds a destructive confirmation before sending the same explicit server command.

## Saved drives, scanner and control containment

DiskSummary groups confirmed locations by device and volume identity, preserving normalized Windows/UNC paths, evidence, counts and last-scan dates. ScannerReview reads the existing paginated unmatched route and resolves a frozen title version through the unchanged backend. Imported or existing library identities share the same confirmation callback. The isolated DEBUG fixture validates the complete request before adding the mapping and removing the pending scan; watch history stays unchanged. Unsupported fixture routes fail explicitly.

Build 14 places Files/Scanner/History dismissal in the fixed header because child bottom safe-area controls were covered by the root capsule. Trakt uses one AnyLayout action subtree, avoiding duplicate hidden accessibility candidates from ViewThatFits. These native idioms preserve existing actions and add no web/backend routes. Real scanner ingestion remains PC-only.

## Discovery and unified search (build 15, awaiting CI)

DiscoverySection/DiscoveryFilters mirror discovery.ts and explore-sections.ts, including supported genres by media kind, validation precedence, stable sort ties, local never-started planned titles and the JavaScript 32-bit daily hash. DiscoveryResults separates each shelf/grid generation, retains confirmed items on append failure and validates page identity. LiveDiscoveryService wraps unchanged authenticated routes with a private 16-entry, five-minute query cache; sign-out rejects cached access. Trakt movie/show recommendation failures remain independent and never erase a successful type. There are no fallback personal scores.

Search uses /api/search?scope=online for provider identity resolution and the complete native workspace for local NFKC substring matches. Provider failures do not hide local results. The existing metadata-only helpers are removed. IMDb URL normalization accepts only the product's IMDb host pattern; provider paging is bounded to 500. Request generations/cancellation keep stale query/page responses out of the visible pane. A newly identified title missing from the snapshot is refreshed before opening or scanner selection. Root page search remains inside scrolling content, so long result sets cannot consume the fixed header/safe area.

Only isolated test provider responses changed: discovery now filters/sorts/pages the same deterministic catalog for both Playwright and Swift fixtures, and search returns the actual combined-response envelope. Captures cover 78 primary states, including new section/filter/paging/global-search states. No source web UI, API handler, D1 schema or hosted data changed.

## Reactive title/editor and watch fixture regression (build 16, awaiting CI)

A title card refresh key contains its selected season, own history, episode metadata and manifest; Undo/other history changes can no longer leave its @State card stale. Default season selection mirrors nextEpisode's aired/unskipped regular order, with the first regular manifest season fallback; a user's explicit selection remains stable. Episode windows use the source next identity and do not backfill extra rows at the end. Editor initialization and season configuration are guarded across pushed cast screens, preserving unsaved notes and expanded episode state. Notes save limits use UTF-16 length as the existing JS API does; keyboard dismissal is native.

FixtureWatchHistory is DEBUG-only and has no URLSession/network dependency. It stages a complete workspace and receipt before publication, retains operation identities across Undo, rejects changed retry intent/stale event versions, derives status only for actual event changes, preserves prior movie viewings and removes receipts only when titles are purged. The real local probe exercises the unchanged Worker/D1 routes independently; fixture tests do not substitute for backend contract evidence. Progress-status transactions and provider imports are still outside this fixture's supported routes and fail explicitly.

## Public score cache (build 17, awaiting CI)

CommunityRatingsController mirrors community-ratings.svelte.ts: unique IDs reserved before awaiting, sequential batches of 24, 24-hour rated/unrated cache, 60-second missing/provider-error cache, and a session generation that discards late responses. Cancellation never caches a failed score or blocks retry. No personal scores or cross-provider fallback enter the projection. Provider outages produce the existing Library rating message, while authentication errors still flow through the common authenticated transport. Preparing the complete collection avoids cancellation when newly arrived scores reorder filtered results. All state resets on sign-out; nothing is persisted to the diary or backend.

The DEBUG-only provider fixture uses distinct synthetic public/personal scores for regression. Playwright intercepts the same actual ratings response envelope; two additional reference states cover available and unavailable public Trakt scores. No web product code or backend route changed.

## Title layout and rating refinement (build 17, awaiting CI)

Live DOM measurements at 402×778 confirm the source title cover at x14/y136/114×171, metadata 14.4pt, rating row 44pt and hero height 380pt. Native keeps the existing system navigation toolbar and adjusts content within its safe area. InlineFlowLayout wraps intrinsic rating controls without retained duplicate accessibility candidates. The source rating panel expands inside progress and autosaves half-point slider changes through the existing versioned title PATCH; explicit Clear/Rate commands use the same transport. An extra native-only Remove latest watch row is removed; existing per-episode toggles, movie slider and Glance removal remain. Screenshot comparison is pending CI; geometry measurements do not constitute visual acceptance.

Successful authentication to a different cache scope clears the old in-memory snapshot and pending owner intents before restoring the new owner-scoped encrypted copy. A failed new-owner reload cannot reveal the previous account. Retained discovery services check the store session revision before reading or publishing cached pages, including recommendations. Failed authentication restores the previous credential and does not clear its diary. No credentials or cache claims authorize backend requests; server validation remains authoritative.

## Person and filmography (build 17, awaiting CI)

PersonSections mirrors people.ts including confirmed-disk identity by media kind, newest shelves, public vote threshold, Self-role exclusion and short TV guest-role prominence weighting. PersonFilmographyFilters uses source NFKC/UTF-16 query rules, validation precedence, source collection selection and stable source sort ties. Forty scenarios are generated by the actual web functions and checked in Core regression; same-ID movie/TV/manual library navigation has a separate identity test.

Native profile now presents source birthday/place, collapsed biography, facts, source-role return, server shelves, Known for, shows/movies and attribution. Typed filmography routes have native filter menus, 40-at-a-time expansion, loading/error/empty states and fixed safe dismissal. Public person metadata shares the source's 32-entry/15-minute session cache, so returning from a title can restore a populated grid before scroll restoration. Session changes clear it; all production reads remain authenticated. Fixture-only tests make no provider calls. Profile/shelf/full-grid screenshot acceptance remains pending.

## Simulator-diagnosed gesture arbitration (historical build 17; superseded in 25)

Build-16 recordings establish two distinct conflicts: Glance's simultaneous drag logged a watch then activated its child NavigationLink, and a title range drag initiated the iOS 26 full-content interactive pop. ProgressCard now guards only title navigation during a recognized swipe and its release animation; vertical scrolling and plus/minus remain independent. EdgeSwipeBackOnly uses the public UINavigationController.interactiveContentPopGestureRecognizer property during title/person lifecycle, restoring its previous state when leaving; it preserves the standard edge recognizer and Back button. Apple reference: https://developer.apple.com/documentation/uikit/uinavigationcontroller/interactivecontentpopgesturerecognizer . CI must prove the range commits a real Undo receipt without leaving the title.

Current build 25 removes EdgeSwipeBackOnly and retains UIKit's native full-content content-pop behavior on title/catalog/person/Explore routes. TrackSlider disables that recognizer only during its active tracking, then restores it on end/cancel/window removal. The early build-25 physical slider/watch/Undo/movie preflight passes; full-content return and tab scrub tests remain in the running full UI suite. The earlier paragraph describes the historical workaround, not the current implementation.

Paging regression additionally requires the entire Load more bounds above the capsule; bottom clearance permits that on long section/filmography grids. The notes/cast regression now opts into a DEBUG-only linked-metadata workspace variant because the baseline title is manual with no provider ID and correctly has no cast. Production/manual behavior is unchanged.

## Catalog preview and import follow-up (build 19, pending CI)

Catalog previews reuse the saved-title hero/backdrop. A per-screen season controller caches hidden/revealed responses from the existing read-only metadata season endpoint, discards stale/cancelled responses and retains rows when an upgrade fails. Four-row windows, explicit expansion and per-episode reveal mirror TitleScreen; watching controls remain absent until import. Series manifests determine unloaded progress totals. Movies do not request seasons.

Add to Planned submits the provider's suggested category and a null personal score to the unchanged idempotent metadata import endpoint, then publishes only a complete workspace reload. Confirmed import followed by refresh failure explains safe retry. Only the explicit DEBUG mutation fixture simulates imports; it preserves existing personal data, rejects archived identities, separates movie/TV identities and never fetches or mutates hosted data. Catalog preview episode rows never enter the workspace merely by browsing.

Manual add retains one caller-generated identity for uncertain retries, sends only the existing create-input fields, and matches source NFKC/UTF-16/control-character/year/score validation. Completed is initially created Planned, then the existing progress/status transaction runs; failure keeps the form and identity available. Both manual/provider create paths reject stale-session publication. DEBUG-only manual creation mirrors immutable identity conflict and preservation of existing personal fields; production still uses the original Worker API.

Provider-linked saved titles automatically prepare their selected season when its source metadata version/age or loaded count is incomplete. The existing metadata endpoint remains the only server preparation path; a complete atomic workspace reload publishes the result. Per-season UI request generations/cancellation protect rapid selection, and preparation failures stay beside the episode list with Retry. No personal watch is logged by preparation. Manual unlinked titles never invent provider episodes. Source six-hour freshness and unchanged event/title identity are covered separately from fixture rendering.


Random-pick overlay uses a containing modal accessibility element and escape-to-dismiss, with the underlying diary hidden from accessibility while open. API references checked: https://developer.apple.com/documentation/swiftui/accessibilitytraits/ismodal and https://developer.apple.com/documentation/swiftui/accessibilityactionkind/escape . Physical VoiceOver focus/gesture timing remains in DEVICE-CHECKS.md. Library initials and ordinary clapperboard/name placeholders remain distinct, matching Poster.svelte; missing hero images use TitleScreen.svelte's backdrop gradient.


## Current unaccepted build-21 follow-up

HistoryQuery shares a parsed-date ordering and row projection between Home and History; date-only ranges are evaluated in the device calendar, unknown dates remain independent, and repeat badges use evidence outside the current filter. Nineteen generated activity.ts cases and nine homeOverview cases are committed. Home reuses the discovery Planned ordering rather than storage order, and its minute/foreground clock refresh never performs a backend write. TraktOverview mirrors More's source summary priorities and excludes stale review counts when disconnected or expired. DEBUG scenarios cover disconnected/reconnect/scanning/unavailable states without provider traffic. These changes still require macOS compilation and screenshot review.

The next workflow allowance is 120 minutes with bounded Core/UI stages. Native intermediates are cached only after successful ordinary builds; restored data never skips xcodebuild dependency checks. Indexing is disabled for CI and build timing summaries are retained. Cache effectiveness remains unmeasured until a later run uses it. Local YAML syntax was checked with the existing Prettier parser; local Bash and Swift are unavailable, so shell execution and all native compilation remain CI-only.

The unresolved saved-progress drag/Undo/movie UI regression now runs immediately after simulator compilation, before Release compilation. Full unit/UI and extra-device suites still run afterward. ProgressGate.xcresult and its retained screenshots use their own artifact folder/labels, preserving the primary evidence without duplicates.


## Confirmed writes and snapshot recovery (next batch, CI pending)

DiaryStore.perform distinguishes action receipt from the complete follow-up read. An action that returned normally remains acknowledged if the refresh fails: return true, retain its Undo receipt, keep the prior complete workspace, and show a dedicated Saved/Refresh notice. No second automatic refresh or repeat write is issued. canMutate/writesBlocked gate subsequent personal mutations and Undo until a complete snapshot publishes; refresh and navigation remain available. An authentication rejection during that read also requires sign-in. A stale session response can never reinstate the notice, data or Undo after sign-out. Switching owners clears recovery state; reconnecting the same owner retains it until reconciliation succeeds.

An action that itself throws remains unconfirmed: existing operation IDs, partial season transactions, version checks and reconciliation behavior are retained. No optimistic personal-data patch, offline write outbox, wire-format/API/backend change is introduced. Confirmed state is currently session memory, like existing pending write identities; app termination and real-device background behavior remain hardening checks. Catalog/manual import already have identity-preserving dedicated refresh messages and are not rewritten in this batch.

Four URLProtocol regressions and one DEBUG-only synthetic read-outage UI flow exercise this contract. The fixture applies the real fixture write, fails only its immediate snapshot read, then allows explicit refresh to reconcile exactly one added event and Undo it. Default fixture screenshots and production data are unaffected. Native compile/test/screenshot evidence is pending, so these statements describe implementation intent rather than accepted runtime proof.


Workspace reload now launches titles/episodes/events/locations concurrently, matching the source live-diary.svelte.ts Promise.all. Pagination within each section remains ordered. Structured async-let lifetimes cancel/await siblings on failure; publication occurs only after the complete tuple, task cancellation and both session/snapshot checks. Held URLProtocol responses prove parallel starts without timing measurements, and each section's outage must preserve the prior complete workspace and cached copy. The older-refresh regression waits specifically for its delayed title request rather than an unrelated section. Actual native compilation/regression and speed measurements are pending the next CI batch.


Library presentation indices rebuild with each complete workspace value: title identities, active events and episodes grouped by title, per-title LibraryProgress and confirmed-location ID set. Visible grid/list cards and their accessibility values use those lookups instead of repeatedly scanning all watches/locations. The Core full-workspace LibraryProgress function delegates to the same per-title calculation; manifest totals, distinct regular episodes and movie history semantics stay unchanged. Sign-out replaces the workspace and clears all projections. A regression covers repeated viewings and replacement. Other rendering projections and main-actor cache/JSON work remain open; no measured frame-rate claim is made before CI/device profiling.


## Navigation surface parity follow-up (build 23, not compiled)

The source phone bar uses a near-black gradient over a blurred backdrop in every ordinary accent theme, with separate glass fill and sheen tokens. Native previously exposed the uncolored system material and therefore appeared too gray in the build-21 side-by-side. DiaryNavigationSurface retains the first-party material, layers source nav fills/edges and honors reduced transparency. DiaryNavigationSelection uses the source accent gradient or glass white highlight; Liquid Glass labels are neutral white rather than tinted accent. Native material blur is an approximation of CSS backdrop-filter, not a claim of identical WebKit sampling. Existing all-theme screenshots and all-size navigation hit-bound checks remain acceptance gates. No private UIKit API or third-party blur library is used.


## Shared discovery and recommendation reads — prepared after build33

DiscoveryCache is owned by DiaryStore, bounded to16 in-memory metadata pages, with a5-minute fresh lifetime and explicit stale reads. Separate LiveDiscoveryService instances share this cache and its in-flight reads. Disappearing/cancelled shelves cannot cancel another consumer; session/account invalidation cancels shared work and rejects cancellation-ignoring replies. Private recommendation keys include a verified Trakt username and are never reused without that identity. Connection status is coalesced only while pending, then checked again on re-entry so an external account change/disconnect clears personal cached pages. No token, personal recommendation or username is newly persisted on disk.

Recommendation movie/show reads run concurrently and use a shared24-per-type page; shelves display8/type, sections24/type, preserving movie/show source order and identity deduplication. After current-account verification, expired metadata stays visible while refreshed; a successful media type replaces its own items while a failed type retains its prior items with an honest retry message. An explicit Retry bypasses fresh metadata, without duplicating an already pending request. Account/session changes immediately discard visible items; late responses cannot replace a new owner. Access connect invalidates both before and after authentication, preventing a read begun with the previous credential from surviving. Disconnect invalidates before and after its request, and successful Trakt reconnect invalidates the cache. Cached metadata's inLibraryId is re-derived from the current active workspace before publication, preserving import/Trash/restore routing.

Seven cache and two controller tests cover shared cancellation, stale refresh/outage/retry, bounded storage, unknown identity, connection-status revalidation, old-session/account replies, actual parallel request start and per-type partial success. Source/syntax review is local; macOS compilation/runtime acceptance is still required. The existing backend/routes and hosted data are unchanged.


## Build35: native chrome, readable hero and Glass backdrop (prepared)

Latest owner feedback supersedes the source hero composition: identity moves lower over a stronger black gradient; synopsis is full width beneath, retaining its leading lines during overflow expansion. The true name's scroll-viewport visibility changes one Bool only at the boundary. System navigation owns the compact poster/name, public Share, Back and material background. No per-pixel shell mutation, scaled text bitmap, custom pop recognizer or changed gesture delegate. Pushed destinations use system Back; modal editing may retain Done.

GlassArtworkCache is a separate actor with coalesced public-only TMDB requests,128px ImageIO decoding and12-entry in-memory storage. Dominant color is sampled from a32px explicit RGBA buffer, excluding transparent/letterbox pixels with deterministic ties. Only immutable CGImage data crosses to SwiftUI. No diary credentials/cookies, third-party framework or disk persistence. Foreground images remain sharp; only the background is blurred. Reduce Transparency restores solid surfaces; Reduce Motion disables decorative springs. Native Glass controls share containers where adjacent. Phone profiling and final screenshot/regression validation remain necessary.

## Access browser recovery — prepared build38

The ephemeral WebKit browser now reports loading/process failures inline and offers a fresh retry. Cookie observation and trusted-backend finishes handle delayed cookie propagation. A short bounded recheck begins only after the backend /api/session response finishes; entering credentials and 2FA on the identity provider is not timed out. Unique attempt tickets invalidate callbacks after Cancel, teardown or Retry, and completion is once-only. The cookie candidate must be secure/unexpired on the exact protected application domain with an API-matching path and valid bounded header bytes. DiaryAPI still validates it with the server before saving to Keychain. Existing-item updates explicitly retain WhenUnlockedThisDeviceOnly protection. No server, cookie-binding or Access policy change is made.

Eight native lifecycle/policy tests are prepared; actual identity-provider login and existing-device Keychain migration remain device checks. APIs checked against [Apple cookie observation](https://developer.apple.com/documentation/webkit/wkhttpcookiestoreobserver) and [Cloudflare authorization-cookie documentation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/). Provider/team global cookies are distinct from the protected application's cookie and are not accepted here.

Both native CI pipelines retain early-gate failures while collecting complete primary/all-phone diagnostics after successful native unit tests. Device packaging/passed early evidence still require the early gate to pass; final summary rejects any missing/failed gate. This expands failure evidence, never release acceptance.


## Incoming Trakt watches — prepared native40

The incoming scheduler remains a client of the same D1/OAuth backend. See [backend design and Free-plan bounds](../../../docs/TRAKT-INCOMING-SYNC.md). Native IncomingTraktController is independent of the reviewed two-way controller: it uses the owner API, enables/disables only after acknowledgement, serializes setting changes, retains honest unavailable/cooldown/paused/review states and never embeds credentials. A DEBUG-only service exercises the setting without touching Trakt/D1. No spinner timer or global status overlay.

Root scene activation calls refreshOnForeground, coalescing ten-second scene churn and waiting for pending write receipts before starting the existing complete workspace load. Cancelled foreground waits do not consume the next resume. Account/session replacement clears the debounce and fences pending work. There is no phone background timer. Five controller and three foreground tests plus one UI toggle scenario are prepared for macOS CI; syntax checks alone are not acceptance.

## Performance and Release hygiene — prepared native41

Paginated workspace responses retain the restricted main-actor request/authentication transport, then decode immutable Sendable pages on a detached task using a private JSONDecoder. Parent cancellation cancels that task; cancellation and session generation are checked again before any page is accumulated. Three held-decoder/URLProtocol cases exercise actual off-main decoding and sign-out/cancellation races. Small DTO decodes and protected cache encryption/disk work remain separate audit items.

Home and Stats use one bounded projection each, invalidated by every workspace replacement and local-day/calendar or time-zone/range/year changes. Reading the observed workspace preserves view invalidation; ignored internal cache writes cannot cause a render loop. Existing Core rules/order are unchanged. Four tests compare snapshot/day/zone/range results and record a synthetic 1,000-event cold/warm diagnostic benchmark without hardware-specific timing assertions. The cold calculation still runs on the main actor; these changes do not establish physical scroll smoothness.

Disposable PreviewData/PreviewCatalog code is DEBUG-only. Release build settings exclude catalog/Trakt/workspace fixture JSON and device packaging fails if those files remain in the actual .app. Real demo artwork and attribution are retained because the live backend can return demo paths. The existing Release isPreview=false policy already prevented UI-test launch arguments from enabling preview writes; this is package hygiene, not a claimed newly exploitable auth fix. Native41 remains uncompiled until macOS CI verifies all these gates.

### Destination-owned chrome and root swipe arbitration (native44)

The bottom capsule and Undo overlay now belong to each destination through DiaryPageChrome. Non-detail roots/lists keep the capsule; title/person details do not. UIKit moves the owning page and chrome together on push, pop and cancelled interactive pop, instead of a global post-presentation Bool changing the entire shell's safe area. NativeNavigationAppearance still observes real containment for diagnostics, but no longer drives geometry. Per-tab NavigationPath values remain intact.

RootTabSwipeInput installs one public UIPanGestureRecognizer on the attached root hosting view, removes it on disappearance and refuses any pushed stack/active transition/presented sheet. Rightward completion advances once through the owner's requested tab order; leftward reverses, never wraps. Vertical or short drags do nothing. Horizontal scroll ancestors, native text/slider/switch controls and explicitly marked card/scrub regions own their own input. Exclusion geometry is inspected at touch-down, not per frame; no private UIKit selectors, synthetic native Back, remote package or continuous shared scroll-offset state. Reduce Motion disables tab-switch/compact-title animations.


### Shipping resources and test support (native51 candidate)

The synthetic SampleWorkspace and workspace.json now belong to the separate
TwilDiaryTestSupport package product. Only Core regression tests and the native
unit-test target depend on it. The shipping application depends on TwilDiaryCore,
which has no test fixture resources or SampleWorkspace API. Golden reference
JSON remains in the package test target. This fixes the previously confirmed
workspace.json resource in the43 production IPA; it does not alter any real
backend snapshot, demo artwork or user export.

Both providers run the same built-bundle verifier during packaging. It rejects
nested workspace/reference/catalog/Trakt/golden JSON and any test-support bundle,
including an empty one. Its three local Python regressions cover the old Core
bundle leak, all fixture filename patterns, legitimate attribution JSON and a
missing app. Local source checks are not proof of Xcode target linking: Core,
native tests and the physical Release bundle gate must pass on Codemagic before
this candidate can be promoted. XcodeGen2.46 package product selection follows
its pinned ProjectSpec.md dependency contract.
