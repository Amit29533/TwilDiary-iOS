# Full application audit — 23 October 2026

The polished `/preview` application is the sole live interface. Home, Library, Glance, Stats/history, Explore, title details, cast profiles, Files and More use its shared real-library controller. Legacy `/diary` routes redirect. Earlier reports describing two independent interfaces are historical.

## Corrections

- Library Movies now includes anime movies in both the UI and API. Queue filtering composes with watch status, has a validated API parameter and cannot reuse another filter's pagination cursor. Queue remains independent of Planned.
- New TMDB imports retain valid IMDb identities. Local search accepts both IMDb codes and pasted IMDb URLs without requiring another provider lookup.
- A background workspace refresh cannot overwrite a newly confirmed edit. Bulk actions and Trash use the versions the user reviewed, rather than silently substituting newer versions.
- Definite rejected watch submissions can be corrected and resubmitted. Uncertain network failures retain the original operation identity for duplicate-safe reconciliation. A reconciled successful watch offers Undo.
- Partially interrupted multi-episode Undo retires only confirmed removals, retaining the remaining work for retry. Conflict refresh clears invalid Undo actions.
- Turning off spoiler protection loads the actual episode details. Season requests are deduplicated only while in flight; failures can retry and stale metadata refreshes after six hours. Previously revealed details survive a concurrent hidden read.
- Trakt history imports update watch status using the same rules as local watches, atomically with the event. Already linked events preserve subsequent deliberate status edits. Pending watchlist proposals are recomputed when an import changes Planned to Watching or Completed. Fixture tests cover rollback and repeat imports; no owner-account sync was applied as a test.
- Movie menu navigation now targets the watch logger. Manual rating input accepts half-point increments and maintains editable form state.
- Files describes the last actual scan evidence instead of presenting it as a sample. Scanner review no longer shows a misleading empty-success message after a load failure.

## Cast browsing and layout

Cast profiles have heading-level View more links for Known for, Shows, Movies and On your server, including each displayed local shows/movies row. Links do not depend on exceeding a shelf-size threshold. Longer shelves show a bounded preview; the full collection opens vertically in the shared poster grid.

The full pages use Explore's top heading and a person-specific subheading such as “Actor's Shows” or “Actor's Movies”. A compact filter icon opens sorting, genre, year, minimum score, search and server-only controls. Filtering and sorting operate on the full filmography before its 40-item display pages. Public metadata caching and SvelteKit snapshots preserve loaded content and browsing state on return from a title.

Only the exact cast hero route owns its header. Nested filmography routes retain the shared Explore header and iPhone safe-area spacing. The cast profile back button now sits in a sticky toolbar for the full page, with safe-area padding and click-through space around its button. Navigation and the previously owner-confirmed swipe snapshot fix remain unchanged.

## Verification

`npm run verify` passes: zero app/worker type errors or Svelte warnings, 249 unit/database/controller/auth/runtime tests, the production Workers build and three compiled service-worker tests. Tests use disposable database/provider fixtures. The production dependency audit reports zero vulnerabilities.

Read-only HTTP checks confirm the local app and cast filmography routes are served through the Wi-Fi listener. The trusted LAN development server uses port 5180; local and hosted databases remain separate.

The verified build was deployed to the existing private Worker as version `34fac32c-f67f-4577-b86a-0b4a416b5f52`. No database migration or Access policy change was needed.

Local browser automation is disabled in Work settings, so this audit does not claim new browser screenshot validation or physical iPhone validation of the cast toolbar. The earlier swipe fix was explicitly confirmed on the owner's phone: no black screen and correct restored scroll position. No real drive scan, destructive database cleanup, owner-account Trakt sync, commit or push was performed for this audit.

## Work still required

These are unfinished roadmap features, not complete features hidden behind existing controls:

- Standalone Windows scan producer, authenticated upload/revocation and interrupted-upload recovery. Drive mappings and manual mismatch review already exist.
- Durable private offline cache and mutation outbox with reconnect/conflict handling. Current private writes require a connection; public service-worker caching is not offline diary synchronization.
- Verified backup restore/import preview and recovery. JSON export and the one-time demo migration do not constitute a general restore flow.
- Metadata correction/merge, editable tags and custom lists.
- Automatic discovery of new seasons and wider title-metadata refresh beyond selected-season refresh.
- Real-account application of reviewed Trakt changes, live expiring-token rotation, and a separate check of service-worker registration behind hosted Cloudflare Access. Existing fixture tests and compiled-worker checks do not certify those live workflows.

The five-phase development plan retains its original acceptance criteria. It should not be read as a claim that these remaining phases have shipped.
