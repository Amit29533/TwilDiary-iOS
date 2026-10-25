# TwilDiary

A new personal media diary for iPhone and desktop. Built around quick episode updates, an artwork-led library, and Windows drive mapping.

The native SwiftUI app is developed separately in [TwilDiary-iOS](https://github.com/Amit29533/TwilDiary-iOS). This repository remains the web app and shared Cloudflare backend.

## Development status

The polished `/preview` workspace is now the only application, backed by the real D1 APIs. The former `/diary` URLs redirect to it. Home, Library, Glance, Stats/history, Locations, Explore, More and title screens share one controller and design. The existing sample library was migrated once into D1 and remains marked as demo data so it is excluded from Trakt exports. Existing real titles and history are preserved.

TMDB search/import, lazy season metadata, watches/Undo, notes, ratings, Queue and Trash use the backend. Trakt PKCE sign-in, reviewed two-way history/ratings/watchlist sync and personal recommendations are implemented. The final web audit and connected test-account sync audit passed; see the release and Trakt audit reports below for coverage and remaining physical iPhone and Capacitor checks. See [hosting and Trakt connection](docs/HOSTING-AND-TRAKT-CONNECTION.md) for hosting details; earlier reports describe previous development stages.

Selected stack: SvelteKit 3 + Svelte 5 + TypeScript, Cloudflare Workers/static assets, D1 with Drizzle, Cloudflare Access, and TMDB metadata/poster URLs. The owner approved Cloudflare account login while Google OAuth remains deferred. R2 is deferred. The fresh hosted project uses the free plans.

## Run locally

Requires Node 24 or later.

```sh
npm ci
npm run db:migrate:local
npm run dev
```

Open `http://127.0.0.1:5180/preview/home`. This is the real local D1 workspace. On first use, the app migrates the existing Preview snapshot, or seeds the marked demo library if there is no snapshot. Local and hosted D1 are separate databases; local edits are not automatically uploaded to the host.

For direct phone testing on trusted Wi-Fi, follow [local phone testing](docs/LOCAL-PHONE-TESTING.md). For private HTTPS access, open [the hosted app](https://twildiary-v2.amit29533.workers.dev/preview/home) and sign in with the owner's Cloudflare account.

For the owner-approved PC-only mode, set `LOCAL_DIARY=1` in ignored `.dev.vars` and apply local migrations. Open `/preview/more` for the masked TMDB and Trakt setup fields. Provider credential setup requires a loopback hostname and socket. Optional trusted LAN access is separately enabled and all development bypasses are compiled out of production. Deployed read/write routes require verified Cloudflare Access. Never commit `.dev.vars` or paste credentials into chat.

```sh
npm run verify
```

This runs app/worker type checking, unit/database/auth tests, the Workers build, and runtime tests against the compiled service worker. The browser review procedure and verification limits are recorded separately in the phase reports.

- [Five-phase development plan](docs/DEVELOPMENT-PLAN.md)
- [Full application audit, cast browsing pages and remaining work](docs/FULL-AUDIT-2026-10-23.md)
- [Final release audit, browser coverage and device checks](docs/RELEASE-AUDIT-2026-10-23.md)
- [Connected Trakt audit, sync fixes and live results](docs/TRAKT-LIVE-AUDIT-2026-10-23.md)
- [Status, slider progress and reversible completion/reset rules](docs/STATUS-AND-PROGRESS.md)
- [Real Home/Glance/Stats, Trakt setup/sync and verification](docs/REAL-DIARY-AND-TRAKT.md)
- [Live TMDB integration, credential setup and verification](docs/TMDB-INTEGRATION.md)
- [Local preview and verification report](docs/PHASE-1-REPORT.md)
- [Reference design alignment](docs/DESIGN-ALIGNMENT.md)
- [Latest daily-use polish, Disk Map, genre rows and verification](docs/DAILY-USE-POLISH-REPORT.md)
- [Explore, fixed headers, carousel and chart polish](docs/EXPLORE-AND-NAVIGATION-REPORT.md)
- [Collection actions, Trash, TwilDiary branding and surprise picks](docs/COLLECTION-AND-BRANDING-REPORT.md)
- [Latest interaction polish, inline search, scanner review and offline scope](docs/INTERACTION-AND-OFFLINE-REPORT.md)
- [Library/history backend progress and API contract](docs/PHASE-2-REPORT.md)
- [TMDb, real workspace and compact UI increment](docs/METADATA-WORKSPACE-REPORT.md)
- [Product and interaction specification](docs/PRODUCT-SPEC.md)
- [Research and reuse decisions](docs/RESEARCH.md)
- [Selected architecture and hosting setup](docs/ARCHITECTURE.md)
- [Earlier backend comparison (superseded)](docs/BACKEND-OPTIONS.md)

This checkout is separate from the old Twil application and Netlify site. Only the new Cloudflare project is used. Local credentials, diary databases, exports and generated build artifacts are excluded from Git.
