# Main tabs and iOS back navigation

The five main routes are Home `/preview/home`, Library `/preview/library`, Glance `/preview`, Stats `/preview/activity` and More `/preview/more`. Main tab changes replace the current root entry. An ordinary tap on the active tab is a no-op, preserving its current filters. Modified links still work normally.

## Audit

Previously, both desktop and mobile tabs were ordinary pushing anchors, visible on drill-downs too. Home shortcuts, search-to-Trash and explicit detail-to-Library exits could push main routes. The title back arrow replaced the detail with Glance rather than going back; the person back arrow pushed a title. Importing a catalog title pushed a saved detail on top of the catalog page. These accumulated earlier screens behind the main tabs.

Library and Explore filter URLs already used shallow replacement. They retain replacement and preserve focus/scroll (`reset: false` in the installed SvelteKit 3 API). Global search, sheets and dialogs use component state. Watch, rating and favorite writes use APIs without navigation. The manifest already starts directly at `/preview/home`; the `/` redirect is server-side. Legacy diary redirects and external OAuth/Access redirects are not tab transitions. The explicit Trakt sign-in action leaves the app for the provider; this change does not alter authentication.

## Implementation

`src/lib/client/navigation.ts` is the shared adapter for all programmatic app navigation. Normal anchors pass through the same policy in the persistent app layout. The body click listener runs after component handlers but before SvelteKit's HTML-level link handler, so custom section reveals and canceled/modified links are preserved.

The shared layout renders both navigation bars only on the five main routes, using an exact route allowlist. It keeps the existing shared diary/header providers and fixed navigation placement instead of moving pages between physical route groups. All drill-downs (including Explore, people, files and scanner review) hide both tab bars and offer real back navigation. Desktop content uses the space freed by the sidebar; mobile content no longer reserves empty bottom-tab space.

Drill-down links push one entry. Same-page query/hash changes and catalog-to-saved redirects replace. Detail/person back controls traverse the actual history, retaining the original tab, filter URL and intermediate drill-downs. A cold/refresh/deep-link entry uses a replacing parent fallback instead of leaving the app. Title/person fallback is Library; auxiliary pages use Home. Rare explicit main-route exits (for example, moving a title to Trash) unwind the known app depth first, then replace the existing root.

Depth is app-owned `page.state.twilDepth` plus current-session bookkeeping, never `history.length` or private SvelteKit router state. Cold navigation starts at zero; normal accepted navigations restore the destination's depth. No gesture listener, popstate re-push, dummy entry, back limit or browser-history trap was introduced. Native browser back/forward remains under SvelteKit's control.

## Validation

The actual adapter runs against a deterministic history/router host in `tests/unit/navigation.test.ts`. Checks cover repeated tab changes and active taps, modified links, root shortcuts, nested details and real back traversals, filter/search/hash replacement, catalog import replacement, explicit root exits, cold detail/refresh fallback and invalid depth. Forward entries remain counted after back; tests deliberately do not interpret total history length as current depth.

Full verification passed: zero Svelte/TypeScript errors or warnings, 219 unit/database/runtime tests, a production build and all 3 compiled PWA checks. Read-only HTTP verified the local Home route returns 200. No library data, migrations, commits or pushes were changed.

Physical iPhone gesture verification is still required. Browser control is disabled in Work settings, so an on-screen temporary history counter could not be visually exercised; no debug readout is shipped. Refresh to pick up the release, fully close the PWA from the app switcher and reopen it from the Home Screen before testing. Existing earlier browser/session entries cannot be erased by JavaScript; this policy prevents new tab/filter accumulation and does not pretend to clear the old stack.

On a clean Home Screen launch, cycle through all tabs and repeat active taps: back should do nothing at the root. Open a title from Library: back should return to the same Library filters. Open nested title/person/Explore screens and back through them in order. Refresh a detail URL and use its back arrow: it should replace with Library. Query/filter changes must not add a back step.

Private Cloudflare release: `a3ad921f-6eaf-4285-bc3b-c6cb80dadb65`. The final small visual follow-up reduces Explore's subheading filter glyphs to 18px while retaining their existing tap areas. Type checks, build and the three compiled PWA checks passed again after that change. An unauthenticated hosted request still redirects to Cloudflare Access; access policy was not changed.

Explore follow-up: the shared header hides its back arrow on `/preview/explore` and its section pages. Native back navigation and the history policy remain unchanged.

## Brief dark frame during native swipe-back

The reported screen disappears after a moment. The existing visual feedback ran the same 400ms loader and whole-page entrance on popstate as on forward navigation. Glance cards also began their staggered entrances at zero opacity. These are avoidable transient paint states during iOS's interactive back transition; the exact device compositor behavior has not been independently reproduced.

Back/forward navigation now clears pending feedback immediately and skips page/card/header entrances. The restored-page marker remains through filter and hash changes, so removing a short-lived suppression class cannot restart the fade. Normal route taps retain a short opacity-only entrance; the whole-page translation was removed to avoid transforming the ancestor of sticky controls. Existing effects are canceled before navigation, on pagehide and on a persisted pageshow. Pagehide flushes the visible DOM before it can be frozen. These lifecycle events follow [WebKit's page-cache guidance](https://webkit.org/blog/516/webkit-page-cache-ii-the-unload-event/). There is no forced reload, gesture interception, history re-push or custom scroll restoration.

A local-only regression during implementation passed native timer methods as feedback-host methods, causing an illegal receiver error in the browser. They are now called through closures on their native global. The user confirmed buttons/navigation work again after refreshing the Wi-Fi app. A root-layout integration test uses strict browser timer receiver checks, in addition to deterministic loader lifecycle and history-presentation tests.

### Recording evidence and artwork correction

The supplied 60fps recording showed the actual dark frame: text and controls stayed painted while all the returning Home posters/backdrops briefly disappeared (for example around 1.35s), then reappeared. Safari's native preview showed the previous carousel slide, while the remounted live carousel reset to its first slide. Suppressing route fades alone did not address this image hand-off.

The persistent layout now captures already-loaded visible artwork before leaving a page. A bounded LRU retains detached decoded image resources, at most 32 URLs and 8 million image pixels (roughly 32MB RGBA). It retains no old component DOM trees and preloads no unseen/offscreen library collection. A subtree observer promotes matching returning image nodes to eager loading and synchronous decoding before paint; new/unseen images retain their original lazy behavior. History navigation waits for these existing decoded resources with a 120ms maximum, without adding a spinner or hiding content. Failure/timeout does not block navigation. The Home carousel uses SvelteKit's public snapshot helper to restore its title ID, pause state and immediate scroll position; active-slide artwork is prioritized.

The user refreshed the Wi-Fi app, opened a title from Home, swiped back and confirmed: **“Images stay visible now.”** This is a user-reported physical-phone check, not an independently recorded post-fix video. Full validation passed: zero type/Svelte errors or warnings, 230 unit/database/runtime checks, production build and all 3 compiled PWA tests. Tests cover decoding failure/timeouts, eager/sync restoration, cache LRU/pixel bounds, carousel snapshot restoration/reordering and the prior navigation/timer regressions. No library data, authentication, migrations, commits or pushes changed.

### Full-viewport black screen follow-up

The 03:37:22 recording is a separate symptom from the artwork-only flash in the 04:47:59 recording. Frame inspection shows the entire app viewport, including navigation and text, briefly black during/after native swipe-back; the iOS status bar remains visible. The user reports this still occurs intermittently and explicitly excludes the now-working main-tab/history policy from this request. The artwork confirmation above does not establish that this full-viewport symptom was fixed.

The app no longer returns a decoding promise from `onNavigate` on history traversal. That hook previously delayed SvelteKit's DOM commit by up to 120ms, despite the browser already handling the swipe visually. Previously visible artwork still warms when leaving and receives eager/synchronous restoration hints; it no longer exposes a navigation readiness gate or timeout. Before a route change, the layout now cancels the current entrance and flushes the settled presentation synchronously, before capturing artwork and before Kit changes history/DOM. Forward feedback, the main-tab policy, real back traversal, authentication and cache headers remain unchanged.

Removing the decoding wait alone did not resolve the full-viewport symptom: the user reproduced it again. A temporary local-only trace collected navigation timing and geometry (no title text, title IDs, credentials or query strings). On native popstate (`hasUAVisualTransition: true`), the diary stayed ready, there was no startup overlay, the destination DOM was at opacity 1 and contained content, and route commits completed in roughly 40–60ms. The trace included returns from a title at scroll 0 to Home at 493px, and from a person at 0 to a title at 421px.

[WebKit's native swipe implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/ViewGestureControllerIOS.mm) rejects a destination snapshot when its history item uses manual scroll restoration and its saved offset differs from the current offset. It then displays the snapshot background color without the image. The installed SvelteKit runtime sets `history.scrollRestoration = 'manual'` when its router starts. This matches the intermittent, scroll-dependent black preview, whereas the app's back button does not invoke the native visual swipe.

`preserveSwipeSnapshot` now sets the current entry's standard scroll-restoration mode to `auto` before navigation on iOS WebKit (including iPad desktop user agents). The departing entry keeps its native snapshot eligibility and the new entry inherits it. SvelteKit still applies its saved destination scroll after committing. No custom scroll handler, synthetic history entry, gesture interception, private Kit metadata, cache-header change or browser-history rewrite is involved. Other engines and desktop browsers retain Kit's mode. Existing entries created before the update may retain their earlier setting; verification starts with a refreshed page and a newly opened detail.

The installed Kit exposes the native popstate event, but the app intentionally performs no asynchronous navigation hook for either native visual transitions or ordinary button history. A layout-script integration test exercises both event forms, including browsers without the flag, an interrupted entrance and shallow filters. Focused tests cover iPhone, iPad, iPad desktop UA, iOS Chrome and exclusion of other engines. Relevant upstream context: [SvelteKit asynchronous swipe navigation issue](https://github.com/sveltejs/kit/issues/10700) and [native visual transition event support](https://github.com/sveltejs/kit/pull/14307).

The temporary trace and its development API endpoint were removed before building the release. Full verification passes with zero Svelte/TypeScript errors or warnings, 237 unit/database/runtime tests, the production build and all 3 compiled PWA tests. Local Home returns HTTP 200. No owner data or database migrations were changed.

Deployed private Worker version: `b807418d-9c45-4fab-824b-0b44e1ad17a1`.

The user refreshed the Wi-Fi app and tested scrolled Home → title → swipe back, plus title → cast member → swipe back, confirming **“No black screen; scroll position correct.”** This is a user-reported physical iPhone check. An unauthenticated hosted Home request still returns HTTP 302 to private Access login.
