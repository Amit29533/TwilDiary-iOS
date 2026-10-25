# Library filter cleanup

Library starts directly with Your collection; Continue watching remains on Home. The category row now contains All, Movies, Shows, Anime and the Filters button, with selection moved into the compact collection toolbar. One layout button switches between the poster grid and genre shelves. Poster dimensions remain unchanged.

Disk Map still toggles the horizontal drive selector and preserves the selected disk. While that selector is open, the selected disk is not repeated as another filter chip. Closing it shows one removable disk chip. Normal back navigation and refresh respect the map's open/closed URL state. Queue remains independent and is not added to Disk Map.

Trash and Mapped folders are available inside Filters. Status, genre, availability, favorites, sort and tags remain available; empty tags controls are omitted. Reset is inside the panel rather than repeated beside every disk row. Other active filters have individually removable chips in one horizontally scrollable row. Category/search controls do not duplicate their labels in the summary when already visible.

Filter changes now serialize to the URL without adding navigation history entries. Advanced filter changes, chip removal and disk toggling preserve scroll. Removing one filter preserves the other filters and disk selection. Regression tests cover round-trips, retained layout parameters and suppression of duplicate disk/category/search chips.

Validation: 204 unit/database/runtime tests, 3 compiled PWA checks, zero Svelte/TypeScript errors/warnings and a successful production build. Browser control is disabled in Work settings, so fresh browser/physical-phone visual verification is pending. No schema, owner data, commits or pushes were changed.

Deployed to the existing private Cloudflare site as version `750ca83f-2637-4fec-9439-76e15830e797`.

Queue follow-up: Queue is available in the Status dropdown as a collection filter, while the saved watch-status model stays Planned/Watching/Completed/Dropped. Home now links to `/preview/library?queue=1`; old `disk=downloads` links still resolve correctly and normalize to the independent Queue filter. Queue produces no extra summary chip and no fake selected disk. Real drive, category, genre and other filters can still compose with Queue. Selecting a watch status or All statuses exits Queue filtering; Reset clears it too. No title status, queued flag, history or Trakt data is modified by these filter choices. Regression checks cover Home/legacy links, canonical URLs, suppression of the duplicate chip, independent drive filtering and switching/reset behavior.

Released with the swipe-back artwork correction as `518f1c56-d729-4ab5-82fc-495079062e49`. Validation: 233 unit/database/runtime tests, 3 compiled PWA checks, zero Svelte/TypeScript errors/warnings and a successful production build.
