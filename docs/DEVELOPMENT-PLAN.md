# Twil v2 development plan

Started 21 October 2026. This is a staged implementation plan, not a claim that the application is complete.

Latest status: [Full application audit — 23 October 2026](FULL-AUDIT-2026-10-23.md). The five phases below retain their original exit criteria; they are a roadmap rather than a completion checklist.

## Confirmed decisions

- Private application for one owner; iPhone PWA and Windows desktop are primary platforms.
- New repository: `Amit29533/TwilDiary`. Retain its Apache-2.0 license.
- Fresh Cloudflare Workers deployment, selected by the owner after reviewing hosting choices. Do not link, read credentials from, or deploy to the old Netlify site.
- No commits or pushes until instructed.
- Free services only. Provider quotas must be explicit; do not enable paid plans or assume unlimited free capacity.
- Home is the default opening screen; Glance remains the current-watch panel.
- Unwatched episode names, summaries, and artwork are hidden by default, with explicit reveal.
- Preserve a Windows scanner with drive/folder mappings to titles and seasons.
- SvelteKit + TypeScript, Cloudflare Workers/static assets, Cloudflare D1 + Drizzle, and TMDb search/autofill with poster hotlinks are confirmed.
- Cloudflare Access protects the entire hosted diary, including reads. The owner approved Cloudflare account login; Google OAuth is deferred. Separate narrowly scoped scanner credentials remain planned.
- R2 is explicitly deferred. Text notes remain in scope; self-hosted images and image uploads need a later decision. No bucket access or configuration changes.
- Keep old Windows discovery aliases and fixed/removable-drive rules, plus manually selected roots.
- The owner subsequently chose the polished Preview as the sole real application and retained its marked demo data for later cleanup. Legacy Diary routes redirect to Preview. Backup restore remains planned.
- New application code by default. Reuse isolated old logic only when justified and tested.
- Trakt sync covers watched history, ratings and watchlist ↔ Planned. Removals/conflicts require review; Queue, notes and file mappings remain independent. Ratings round for Trakt while preserving local decimals. Live hosted authorization and reads succeeded; applying real-account changes remains unverified.

## Decisions still open

- Hosted installation is configured on the fresh private Worker. Local and hosted D1 remain separate; ongoing database migration/synchronization needs an explicit workflow.
- Scanner scheduling and multiple-PC details beyond the confirmed discovery/root rules.
- Migration scope and treatment of ambiguous historical episode cursors.
- Any future background Trakt polling budget. The HTTPS callback and Client ID are configured; current sync is manual.

Ask the owner before implementing a product or infrastructure decision that is not established by the conversation. Do independent research and tests while answers are pending. Do not treat unanswered questions as approval.

## Phase 1 — foundations and representative daily workflow

### Deliverables

1. Confirm decisions above and record the selected architecture with reasons and free-tier limits.
2. Inventory the old app; make an explicit keep/rebuild/defer matrix. Study Plekt's behavior without copying its implementation or styles.
3. Set up strict TypeScript, small feature boundaries, reproducible dependencies, local fixtures, tests, and the Cloudflare Workers build adapter.
4. Establish design tokens and accessible primitives: button, icon button, field, selector, checkbox, disclosure, sheet/dialog, toast, menu, skeleton, and empty/error state.
5. Implement a local sample-data slice: Glance → show detail → mark next episode → Undo → return with scroll restored. Include Library and the storage location panel to prove the shared design.
6. Demonstrate desktop sidebar and phone bottom navigation. Keep artwork, title, episode action, and sync feedback prominent.

### Exit evidence

- Type checking and production build pass.
- Primary workflow works with keyboard and touch-sized controls.
- Phone widths 320/375/390/430 and desktop widths 1024/1440 checked for overflow, clipped controls, and navigation collisions; 200% text enlargement remains usable.
- Loading, empty, offline, failed save, and reduced-motion states are reviewable.
- Local visual review is complete before expanding every feature.

## Phase 2 — reliable library and episode history

### Deliverables

1. Implement database migrations, owner-only access, login/logout/session expiry, and paged/searchable library APIs.
2. Separate catalog identities, personal collection state, seasons, episodes, watched events, notes, lists, and file locations.
3. Implement movie watches, individual episode watches/unwatches, skipped episodes, rewatches, known/unknown watch dates, season actions, and undo.
4. Derive progress and Up Next from episode records. Keep title status independent from a finished season; future and undated episodes need explicit rules.
5. Add search → selection → dedicated review/edit → save. Keep primary actions visible without forcing a scroll through search results.
6. Implement favorites, ratings, tags, notes, metadata correction, safe merge, Trash/restore/purge, and bulk selection.

### Exit evidence

- Test gaps in episode order, season 0/specials, unknown counts/dates, new seasons, rewatches, and changing metadata.
- Repeated requests do not duplicate watches. Failed operations are visible and recoverable.
- Correcting a metadata match preserves personal data and locations without leaving a second accidental title.
- Authorization tests reject anonymous and wrong-owner reads/writes; all database reads are scoped.
- Paged results are stable when records share sort keys; selecting all matches cannot silently mean only the loaded page.

## Phase 3 — drive mapping and migration

### Deliverables

1. Implement a standalone PowerShell scanner and versioned upload contract, using synthetic temporary folder fixtures during tests.
2. Map device, volume identity, root, relative path, local copies, title, season, and confidently recognized episode ranges separately.
3. Separate present, confirmed missing, disconnected, and incomplete scan evidence. Never infer watched history from files.
4. Implement scanner pairing/revocation, repeatable uploads, upload recovery, scan summaries, and ambiguous match review.
5. Build a Files / Drives area with per-drive availability, path copy, stale scan indication, title/season navigation, and multiple-copy visibility.
6. Implement old Twil backup import with preview, identity matching, preserved notes/ratings/tags/dates/locations, and a migration report. Keep an untouched recovery copy.
7. Port Excel interchange only after the core migration format is verified; load its parser on demand.

### Exit evidence

- Duplicate upload, interrupted upload, inaccessible folder, unplugged drive, changed drive letter, multiple roots/copies, and malformed paths covered.
- A partial scan cannot mark unseen content missing. A disconnected drive cannot erase file mappings or history.
- Scanner credentials cannot read the private diary or edit watched state.
- Import/export/restore round trips preserve supported fields and explain any unsupported source fields.
- No real drive scan, production import, or destructive cleanup is run as a test.

## Phase 4 — PWA, offline work, and Trakt

### Deliverables

1. Cache public app shell; maintain a separate account-scoped IndexedDB cache and durable operation queue for owner data.
2. Paint cached Glance immediately, then reconcile in the background. Load artwork, later pages, notes, stats, and episode details only when needed.
3. Implement pending/synced/error states, reconnect, retries, conflicts, queue persistence across app closure, and session-expiry handling.
4. Integrate Trakt OAuth PKCE, stable provider IDs, event mapping, incremental pulls, durable push queue, echo suppression, and complete-snapshot guards.
5. Provide first-sync preview, Sync now, last success, pending/failed work, and reconnect/disconnect. Agree removal and decimal-rating rules before outbound writes.
6. Add upcoming episodes and history/statistics backed by actual events. Separate recorded duration from estimates.
7. Validate manifest, Apple touch icon, safe-area layout, installation instructions, update recovery, and offline navigation. Preserve the tested Apple icon approach from the old app only if still appropriate and verified.

### Exit evidence

- Airplane-mode restart, mark watched offline, app closure, reopen, reconnect, retry, and no duplicate history tested.
- Service worker updates never discard drafts or pending operations.
- API responses and credentials never enter a public/shared cache; logout clears owner data appropriately without silently losing queued work.
- Trakt outages, 429s, token rotation, partial history pages, repeated jobs, and deletions tested with contract fixtures before live use.
- No claim that Safari executes scheduled background work while closed. Server work must be bounded and budgeted for the selected free plan.

## Phase 5 — daily-use hardening and fresh-site release

### Deliverables

1. Audit UI routes and overlays across phone/desktop, touch/keyboard, text enlargement, long titles, missing artwork, large collections, and reduced motion.
2. Add useful operational views: last backup, restore preview, sync health, scanner health, storage usage, and actionable failures.
3. Bound image uploads and backup retention against the selected free quotas; make export/recovery available.
4. Measure cold and warm startup separately, on consistent network/device conditions. Test long libraries without loading every record or poster first.
5. Run unit, API integration, migration, scanner fixture, accessibility, and browser workflow suites. Record failures and fixes; repeat relevant checks after fixes.
6. Configure only the owner's new Worker, D1 database, hostname and Access application when supplied. Use isolated preview data, verify owner access and rollback/export, then release when instructed.

### Exit evidence

- No known critical data-loss, access-control, or blocked daily workflow issue remains.
- Real iPhone Safari/Home Screen install, opening/reopening, icon, scrolling, sheets, keyboard, and offline updates validated with owner help where physical-device access is unavailable.
- Measured performance report includes device/network conditions and limits. Simulated WebKit checks are not labeled physical iPhone testing.
- Release guide, environment template, migration guide, backup/restore guide, and test report delivered.

## Performance and UX targets

These are engineering budgets to measure and refine, not guarantees about a cold network or hosted database wake-up.

- Cached shell and last-known Glance must paint without waiting for authentication, metadata, or the whole library; protected mutations still require valid authorization.
- Immediate interaction feedback should be visible within 100 ms on the agreed reference device, followed by an honest pending/synced state.
- Initial route JavaScript target: at most 100 KB gzip excluding images; log actual build output and justify exceptions.
- API summary/page target: at most 50 KB compressed for the first normal page; details and large text remain separate.
- No full-library rewrite for a single progress update. Index the actual library and progress queries.
- Size artwork to the rendered context, reserve dimensions, lazy-load offscreen images, and limit simultaneous work.
- Prefer transform/opacity motion; avoid animated backdrop blur, card-wide transitions on every update, or permanent decorative animation.
- A warm cache is an optimization, not the only recovery path. Test cold install and storage denied/evicted conditions.

## Current status

The polished Preview is the only application and uses the real backend throughout. Home, Glance, Stats/history, Library, Explore, cast browsing and Files share its controller. The fresh private Cloudflare Worker, Access policy, hosted D1, TMDB secrets and Trakt authorization are configured. Local and hosted databases remain separate.

The 23 October audit corrected refresh/edit races, recoverable watch/Undo failures, stale reviewed versions, Queue/movie/IMDb filtering, season-cache and spoiler loading, and Trakt-import status transitions. Verification passes 249 unit/database/controller/runtime tests plus three compiled-worker tests, with zero type errors or Svelte warnings and a successful production build. See [the current audit](FULL-AUDIT-2026-10-23.md) for evidence and limits.

Metadata correction/merge, tags/custom lists, general backup restore, the standalone scanner/upload path and private offline mutation synchronization remain unfinished. Trakt authorization and read-only provider access were verified live; applying owner-account sync changes and installed-PWA registration behind Access still need separate validation. The original phase exit matrices are not all complete. No commits or pushes have been made.
