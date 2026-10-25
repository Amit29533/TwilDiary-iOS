# Product and interaction specification

21 October 2026. Confirmed requirements are distinguished from proposals below. This document is a design contract for implementation and testing, not a list of implemented screens.

## Daily job

Open Twil, see what is next, update one episode with confidence, and return to watching. Library management, metadata editing, and diagnostics should not dominate that first screen.

Confirmed: Glance / Up Next opens by default. Private single-owner use. Phone and desktop share behavior, while their navigation adapts to available space. Spoilers for unwatched episodes are hidden unless revealed.

## Proposed information architecture

| Area             | Primary content                                                                  | Occasional actions                                                     |
| ---------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Glance           | Current watches, next released unwatched episode, quick watched action, progress | Change season, history correction, snooze/archive policy to confirm    |
| Library          | Standard poster cards, search, category, useful status/availability filters      | Bulk select, sort, advanced filters, add title                         |
| Title detail     | Artwork, synopsis disclosure, personal state, next episode, seasons              | Edit metadata, ratings, notes, history, locations, Trash               |
| Activity / Stats | Actual watch events, genre percentages, time period                              | Drill into matching titles; distinguish event totals from title totals |
| More             | Files / Drives, notebook, lists, backups, settings, integrations, Trash          | Operational health and recovery                                        |

The exact navigation labels are reviewable during Phase 1; do not invent functional routes that are only decorative.

## Visual system

- AMOLED foundation, soft lavender accent, restrained frosted navigation/overlay surfaces, and artwork as the main source of color.
- Opaque readable fallbacks for unsupported transparency and reduced-transparency preferences where available. Do not blur every card.
- Compact headings and toolbar. Use one short context line when it helps; avoid repeated slogans and duplicated section introductions.
- Familiar SVG icons for frequent actions. Keep readable text where an icon alone would be ambiguous, including destructive actions and sync failures.
- Every icon button has an accessible name and a desktop tooltip where useful. Icon artwork may be small; its touch target remains at least 44 by 44 CSS pixels.
- Body text approximately 16 px; important labels remain readable rather than compressing everything into tiny metadata. Form fields at least 16 px on iPhone to avoid focus zoom.
- Use a small consistent spacing/radius/type scale and component-local styles. No successive global override layers.
- Short intentional entrance/exit and success feedback; reduced motion disables movement without removing state feedback.

## Layout and navigation

- Phone: compact header, bottom navigation above safe area, two-column standard library posters where width allows; no giant dashboard heading above the collection.
- Desktop: sidebar, restrained toolbar, responsive poster grid, comfortable maximum reading width for details.
- Title detail uses a real URL and supports reload, browser back, open in a new tab, and return to filters/scroll position.
- Bottom action bars and keyboard do not cover focused fields, episode controls, or the last list item.
- Dialogs/sheets trap focus, have a distinct close target, restore focus, and leave the background position stable. Favorite and close never share a hit region.
- Keep scroll gutters stable. Avoid global scaling or content-width shifts when menus open/close.

## Core workflows

### Update an episode

Glance shows the next eligible episode with its series and season. Mark watched creates a history event and visibly updates progress. Repeated retries of the same action cannot create another viewing. Rewatch is a separate intentional action. Undo targets that event and does not erase unrelated history. Pending/offline changes remain identifiable.

An unknown watch date stays unknown. A skipped episode is distinct from watched. A finished season does not automatically finish an ongoing series. Rules for completion and changing the next season must be explicit and tested.

### Browse and edit

Library defaults to artwork cards. Filters use consistent height and aligned labels/counts. Search is one field, without a nested second input border. Advanced filters expand on request. Selection has an actual button treatment and clear selected counts.

Selecting a metadata search result moves to a dedicated review/edit step; save remains reachable. Readable title detail comes before secondary edit forms. Failed saves retain input and explain recovery.

### Spoilers

For unwatched episodes, keep episode code, watch action, and release state visible; conceal title, overview, and thumbnail. Reveal is explicit. Source artwork and accessibility text must not leak the concealed title. Whether reveals persist is still a product decision.

### File availability

Show drive and season mappings as compact location rows/cards with copy-path and last-scan status. File existence never sets watched state. Multiple copies belong to one identity when confidently matched.

The scanner is a Windows companion; Safari cannot enumerate Windows drives. The web app manages mappings and evidence uploaded by the scanner.

### Correction, deletion, and recovery

Fix match updates identity with a reviewed merge where needed, preserving notes, history, and file locations. Delete first moves a title to Trash. Restore is clear. Permanent purge and empty Trash explain the exact affected records and attached content before confirmation.

## Required states for each feature

Review initial load, cached load, refreshing, empty, no search matches, partial data, permission/session expiry, network failure, pending save, failed save, offline, and successful completion. Skeletons reserve final geometry. Bottom loading feedback accompanies list paging without blocking already loaded cards. Prefer useful retry actions over raw error text.

## Data principles

- Stable internal IDs with separate typed provider IDs for movie, series, season, and episode.
- Watch events preserve provenance, source identity, optional watch time, and separate modification/sync timestamps.
- Never use a viewing date as a conflict-resolution edit clock.
- Catalog metadata, personal state, file availability, and integration delivery are separate domains.
- Owner-scoped browser persistence and server authorization; no secrets or private file paths in static assets.
- New storage operations are transactional and bounded; first paint does not depend on importing the entire diary.
