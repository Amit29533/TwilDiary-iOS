# Returning to a page

The app remembers view state while its browser tab stays open. Switching main tabs still replaces the root history entry; detail pages still push and Back still traverses real browser history.

`view-memory.ts` keeps a bounded in-memory record of each pathname and normalized query. Bare main-tab links resume their last query and scroll position. Explicit shortcut queries, including Home Queue and Disk Map, keep their requested destination. Hash links keep their section target.

`remember-view.svelte.ts` restores layout-affecting state during component initialization, before the returning page is measured. It also registers SvelteKit's public snapshot helper for individual history entries and saves state before navigation. This prevents a long grid or expanded episode list from becoming short and clamping the saved scroll position during a return.

Remembered state includes Library filters and layout, Glance filters and seasons, Home's carousel selection, Explore and person-grid loaded items, title seasons and expanded episodes, cast biography expansion, selected drive, Stats history filters and loaded rows, and Watch Time period/year/selected bar. Native details elements and horizontal shelves also retain their positions. Write confirmations and unsaved edit drafts are not restored. Library records remain owned by the live diary and its APIs.

The shared layout restores replaced-tab scroll immediately, without animation. SvelteKit retains vertical scroll ownership for native back/forward. The existing iOS `preserveSwipeSnapshot` handling is unchanged; there is no asynchronous navigation hook, custom gesture interception or synthetic history entry.

The RAM store limits positions and component entries to 120 each, serialized component state to one million characters each, and combined component state to roughly 8 MB. Closing/reloading the tab clears this RAM cache; SvelteKit may separately retain its own history snapshots. This feature does not promise permanent preferences or offline data synchronization.

Validation: all 275 unit/database/runtime tests and 3 compiled PWA tests pass, with zero Svelte/TypeScript errors or warnings and a successful production build. Tests cover destination intent, query isolation, cloning and eviction, repeated cache replacement, horizontal/disclosure restoration, carousel restoration, and immediate tab scroll without overriding native history. The interrupted layout, memory module and navigation test were recovered from the saved source/patches before verification. No database migration or owner-data mutation was needed. A new physical iPhone check remains unverified in this session.
