# Live TMDB integration — 22 October 2026

The real diary is available locally at `http://127.0.0.1:5180/diary`. Its data is separate from `/preview` and stored in local D1. The owner connected TMDB through the masked local form. No commit, push, deployment, old Netlify changes, automatic migration or sample-library seeding was performed.

## Implemented

- Inline search independently loads local and online results, supports IMDb IDs, and separates **In Library** from **Not In Library**. Provider identity lookup prevents an existing title from being offered as a new import. Local results remain usable during an upstream outage. Returning from a title review preserves the search query and results; pending requests show loading instead of briefly claiming no matches.
- Title review loads overview, genres, rating, runtime when supplied, season counts and episode totals before adding. Japanese animated titles default to the Anime category; the owner can change the category after the details load. Review never imports automatically.
- Import stores title metadata and season summaries atomically. Repeated imports preserve the existing diary entry, notes, ratings and history. An existing title in Trash requires restoration rather than duplication.
- Opening a provider-linked series automatically fetches just the selected season if it has not been loaded. Stored episode reads are paged; the episode-header refresh action uses a six-hour server cache and preserves watched/skipped state. Unwatched episode names, synopses and artwork remain hidden until explicitly revealed.
- The real Library has compact category/filter/selection controls. The title screen has backdrop artwork, safe-area-aware circular controls, a larger poster, glass tracking panel, collapsed overview, expandable episode details and a retry action for failed initial episode loading.
- More includes a connection check and approved, unchanged TMDB logo/attribution in Credits. Poster URLs use the validated TMDB image host; R2 remains deferred.

## Runtime and credential handling

Adapter 8 exposes bindings through `cloudflare:workers`. The request hook now supplies these through typed request locals to all API routes. Resolving bindings lazily also allows the adapter's Node build process to generate the data-free offline preview fallback.

Local authentication requires all of: the compile-time development build, explicit `LOCAL_DIARY=1`, a loopback hostname and a loopback socket address. LAN requests to the private diary/API are rejected; the sample preview remains available over Wi-Fi. The deployed build always requires verified Cloudflare Access.

The local masked form validates the token before atomically saving it to ignored `.dev.vars`. The token is never returned, logged or stored in browser storage. Same-origin and loopback checks protect this development-only endpoint; concurrent validation cannot bypass the save lock. Production credentials must instead be configured as Worker secrets.

Two DNS-returned TMDB CDN addresses on this PC reset TLS connections during investigation. The development-only Node transport retries connection failures against DNS results and remembers a working address. It keeps HTTPS certificate/hostname verification, the fixed TMDB read API origin, bounded attempts, an abort deadline and a response size cap. It does not retry authentication, rate-limit or certificate errors, change system DNS, or hardcode CDN addresses. Workers use their native fetch implementation.

## Verification

- `npm run verify`: **144 unit/domain/database/API/controller tests + 3 bundled service-worker tests**, zero Svelte/TypeScript errors or warnings, successful Cloudflare production build. Output: `verification-tmdb.log`.
- Regression cases cover request-local D1 bindings, owner guards, loopback restrictions, safe connection responses, validated token storage, concurrent submissions, DNS failover, aborts, fixed-origin restrictions, and bounded retries. Existing tests cover duplicate/concurrent imports, atomic failure, history preservation, pagination, spoiler controls and large seasons.
- A separate local instance of the **built production Worker**, with fixture Access settings and `LOCAL_DIARY=1`, returned **401 + no-store** for diary, metadata, library, development-token and preview routes. Spoofing an owner-email header did not grant access. The temporary instance was stopped afterward.
- The live development server returned **200** for the owner's connection check, **403** for LAN private API access and **200** for LAN sample preview access.
- Built client/server output was scanned privately against the configured token: **zero credential matches**. Production server output contains neither the development owner identity nor Node TMDB networking/setup code.
- Browser checks use the actual live provider: Wednesday is recognized as an existing library entry; IMDb `tt5290382` resolves to MINDHUNTER; reviewing the result does not add it. Wednesday opens with stored season summaries and eight spoiler-hidden Season 1 episodes. Phone geometry is checked at 320/390/430px and desktop; this is Chromium viewport evidence, not physical iPhone Safari certification.
- A transient live metadata failure displayed the Retry action and recovered to the complete review. Provider availability can still affect uncached searches; no instant network-response guarantee is made.
- Live review proof: `screenshots/tmdb-review-phone.png`.

## Remaining work

The subsequent [real diary and Trakt increment](REAL-DIARY-AND-TRAKT.md) delivers Home, Glance, Stats/history and file-location UI against private D1 APIs, plus fixture-tested Trakt OAuth/sync and personal recommendation wiring. That report records the newer test count and live-connection requirements. Cumulative episode-slider parity, metadata correction/merge, scanner ingestion/pairing, backup import/restore and full private offline reconciliation remain outstanding. The sample preview continues separately.

Cloudflare hosting, D1 provisioning, Access/Google login, hostname and real-device PWA validation have not been configured or deployed. The owner has offered to sign in when setup is ready. No cloud login is necessary to use the explicitly approved PC-only development mode.

## Official references

- [Application authentication](https://developer.themoviedb.org/docs/authentication-application)
- [TV season details](https://developer.themoviedb.org/reference/tv-season-details)
- [Images](https://developer.themoviedb.org/docs/image-basics)
- [Attribution requirements](https://developer.themoviedb.org/docs/faq)
- [Approved logos](https://www.themoviedb.org/about/logos-attribution)
