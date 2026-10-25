# Collection management, branding, and surprise picks

Verified locally on 21 October 2026. No commits, pushes, deployments, or cloud configuration changes.

## Implemented

- Collection selection in grid and list layouts, with outlined Select/Done controls, selected-state checkmarks, clear/select-shown actions, and a limit of 60 titles per batch. The real paged library explicitly selects loaded records, not unseen pages.
- Reviewed bulk watch-status and favorite changes, Move to Trash, restore, and permanent deletion. Changing a title's status does not invent episode viewings.
- Preview Trash is accessible from Library and More. Individual title menus can move a story to Trash. Archived titles disappear from daily progress, statistics, history, discovery's local library, and Disk Map counts while their records remain stored for restoration.
- Restoring preserves titles, episode viewings, notes, ratings, and file mappings. Permanent deletion requires typing DELETE and removes associated diary records only; no filesystem deletion or scanner command is performed.
- `POST /api/titles/bulk` uses the existing owner/Access, same-origin write protection, bounded JSON reader, and private/no-store responses. A materialized selection CTE checks every title's expected version and active/Trash state before a single UPDATE or DELETE. A stale, missing, or wrong-state item rejects the entire batch without partial mutation. Confirmation retains the versions of the records actually reviewed.
- Existing schema foreign keys cascade permanent deletion through identities, seasons, episodes, viewings, operation receipts, and locations. Scanner device identities and unrelated titles remain intact. No schema migration was needed.
- Backward-compatible optional preview tombstones; previous saved workspaces remain readable. Preview export includes Trash. Re-adding a trashed identity reports that restoration is required instead of creating another copy.
- List rows now display a poster plus a tinted backdrop, with a dark text scrim and lazy-loaded artwork. Private list summaries include the backdrop path without loading personal notes or episode details. Failed artwork falls back without breaking the row.
- TwilDiary branding on Home, the welcome page, sidebar, document titles, and installation labels. Diary uses the accent colour. Library/Glance/Stats retain their route names in the main header.
- Circular star logo, tap rotation, and occasional rotations at random intervals of 5–12 seconds. Timers stop while the document is hidden; reduced-motion settings suppress decorative rotation.
- A quick triple tap within 850ms opens a random collection pick in the preview. Both desktop sidebar and header logos support it. The tinted dialog has a poster, status, open-title action, reroll, gentle transform/opacity reveal, and brief sparkles. Reroll avoids an immediate repeat when another active title exists. Trashed titles are excluded; empty collections show an add action. Reduced motion suppresses reveal effects. Escape closes the dialog and returns focus to its opener.
- Darker genre-chart palette. Segments support click/tap and Enter/Space selection; the centre and live status show the selected genre and percentage. The legend remains a larger alternative target with the same selection state.

## Verification

`npm run verify`: **100 tests pass, 0 failures; 0 Svelte/type errors or warnings; Cloudflare Workers build succeeds.** Full output: [verification-latest.log](verification-latest.log).

New regression coverage includes atomic rejection of stale/missing/mixed-state batches, preservation through Trash/restore, linked-record purge and foreign-key integrity, owner/API setup protection, deletion confirmation, input limits, artwork summaries, preview archive integrity, archived-title duplicate prevention, random-pick bounds/repetition, and rapid-tap timing.

Browser review used an isolated QA tab at 320px and 390px phone widths and 1440px desktop width. Confirmed list poster/backdrop rendering, no horizontal overflow, selection actions, two-title selection, Trash and restore of one sample title, permanent-delete disabled before confirmation, triple-tap opening on phone and desktop, reroll, Escape/focus restoration, and genre selection through keyboard. The chart measured 240×240px. No browser console errors were reported. No permanent deletion was performed through the UI; purge was tested using temporary SQLite fixtures with the real D1 Drizzle driver. The sample title used for Trash testing was restored.

Screenshots:

- [Collection list with cover art](screenshots/library-list-cover-art-phone.jpg)
- [Collection selection](screenshots/library-selection-phone.jpg)
- [Surprise pick](screenshots/random-pick-phone.jpg)
- [Interactive genre chart](screenshots/interactive-genre-chart-phone.jpg)

These are Chromium phone viewport checks, not physical iPhone Safari validation. The private D1/Access workspace still requires its fresh hosting configuration. Metadata correction/merge, tags/lists, scanner uploads/import, durable offline synchronization, and Trakt OAuth remain subsequent work in the five-phase plan. The surprise interaction currently uses the isolated preview collection; it does not pretend to access a connected production library.
