# Metadata, real workspace and compact Glance increment

21 October 2026. Local development only; Phase 2 remains in progress.

## Implemented

- Owner-only TMDb search by name or IMDb ID, with movie/TV filters, bounded pages, abortable browser requests, an eight-second upstream deadline, bounded response bodies and safe errors for missing configuration, throttling or provider failures.
- Search selection opens a separate review form. The save footer remains visible. Manual creation and initial personal fields save atomically; uncertain-response retries keep their caller identity.
- Provider-based imports are atomic and duplicate-safe. Reimport opens the existing title without overwriting its personal edits/history. An existing item in Trash requires restoration. Movie and TV provider IDs remain separate.
- Imported titles include artwork paths, overview, runtime, genre names, community score and season summaries. Library navigation does not fetch every episode. A selected season loads on request; recent metadata is reused for six hours. Refresh preserves episode IDs, skipped flags and watched records, and never deletes unseen old records.
- D1 migrations add metadata columns without rebuilding or removing existing tables. Migration 0003 was reviewed and applied to Wrangler local D1 only.
- Bounded JSON groups avoid one database query per season/episode and keep metadata statements below D1 parameter/value limits. A 1,000-episode fixture imports in a few statements. Literal substring search uses `instr`, avoiding D1's 50-byte `LIKE` pattern limit.
- `/diary` provides paged/filterable library and Trash, grid/list views, restore, add/search/review, title metadata, selected-season episode pages, spoiler reveal, watches and targeted Undo, notes/rating/status/favorite edits and soft deletion. The frontend calls the real API contracts; it does not copy sample records into the database.
- The workspace displays an explicit setup state while Access/D1 are unconfigured. No new API development bypass, credentials, cloud resources or production changes were introduced.
- Glance preview now uses shorter 4:5 poster crops, a compact season/count row, tighter header/filter gaps and less card padding. The 390 px layout has a first-card top of 126 px and card heights around 181–200 px. All tested card buttons, summaries and selectors retain 44 px minimum hit heights.
- Fixed poster recovery after a failed image URL changes, and aligned real Anime filtering with the preview's inclusion of anime movies.

Follow-up visual comparison: visible controls had all been rendered at 44 px, which made the season selector and filter pills too tall relative to the phone reference. Glance now separates painted surfaces from hit areas: 32 px category pills, an 88 × 26 px phone season pill and 32/34 px episode buttons, retaining 44 px hit areas. The season control still uses a native select with a 16 px input font and a visible keyboard focus indicator. Header/favorite/menu SVGs were reduced to restore the reference's hierarchy. The latest reference adoption supersedes the earlier card measurements above; see [design alignment](DESIGN-ALIGNMENT.md).

## Added endpoints

| Route                                                     | Purpose                                                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `GET /api/metadata/search?q=…&type=all\|movie\|tv&page=1` | Search or IMDb lookup; owner required, D1 not required                         |
| `POST /api/metadata/import`                               | `{mediaType,tmdbId,category,status?,score?,favorite?}`; stable identity import |
| `POST /api/titles/:id/seasons/:number/metadata`           | Load/reuse metadata for one selected season                                    |

Manual creation accepts optional initial `status` and `score`. Episode pages now include progress across the whole season, spoiler-filtered still paths and a versioned latest-viewing reference for targeted removal.

## Verification and limits

- 67 automated tests pass, including new upstream contract, identity, atomic rollback, retry, metadata preservation, large-season, long-Unicode-search and browser API client tests.
- Svelte checking and the Workers build pass with zero diagnostics.
- Browser checks cover the disconnected real workspace/review form, compact phone Glance, overflow/tap targets, episode increment, Undo and menu behavior. The sample workspace uses real local IndexedDB; backend integration tests use the actual Drizzle D1 driver against a SQLite/D1 harness and mocked TMDb responses.
- The authenticated real-workspace browser flow cannot be claimed end-to-end tested yet: no new Access application, owner configuration or TMDb token is supplied. Physical iPhone/Safari tests remain pending.
- Metadata correction/merging, full real Glance/Home/Stats navigation, tag/list/bulk tools, scanner pairing/uploads, migration, Trakt, durable offline sync and production PWA installation remain later work. Latest-viewing removal does not erase every intentional rewatch. Completion status does not invent episode watch dates.
- No commits, pushes, deployments, old Netlify changes or real library imports occurred.

## Primary references

- [TMDb search](https://developer.themoviedb.org/reference/search-multi), [IMDb lookup](https://developer.themoviedb.org/reference/find-by-id), [series](https://developer.themoviedb.org/reference/tv-series-details), [season details](https://developer.themoviedb.org/reference/tv-season-details), [images](https://developer.themoviedb.org/docs/image-basics).
- [Cloudflare D1 limits](https://developers.cloudflare.com/d1/platform/limits/) and [JSON queries](https://developers.cloudflare.com/d1/sql-api/query-json/).
