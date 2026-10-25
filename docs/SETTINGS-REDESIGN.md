# More & settings

More uses compact grouped rows with themed icon tiles, clear status badges and consistent dividers. The groups are Library, Tracking, Appearance & region, Connections, Data & backup, and About.

- Library links to Files & drives and Trash. The undated watches shortcut was removed from Settings at the user’s request; the existing date review tools remain in watch history and Stats.
- The spoiler switch is bound to the existing persisted diary preference and its whole row is labelled for activation.
- Theme opens `/preview/more/appearance` and retains the six device-local themes. Reduce motion, time zone, Monday week start and the decimal rating scale describe the current behavior; they do not show nonfunctional selectors.
- Connections open dedicated TMDB and Trakt pages. Existing credentials, OAuth/PKCE, development-only setup, rate-limit handling, per-item conflict resolution and server-side sync behavior are preserved.
- Trakt’s top summary uses the real connection and pending counts, excluding link-only matches and closed scans. A scan prepares review data. History/rating/watchlist chips filter the loaded batch, with six visible items and Load more. Apply all ready changes retains the existing safe bulk action, independent of the display filter. Conflicts and uncertain sends keep their explicit individual choices.
- OAuth redirects now return to the dedicated Trakt page. Older `/preview/more?trakt=...` links forward there with their result parameters.
- Export preserves the existing archive format. About displays the package version and attribution.

Settings subpages and Files & drives have no top back arrow. The primary navigation remains available, with More active. These routes retain normal nested history depth and swipe-back behavior; they are not added to the root-tab history policy. Files & drives uses a stacked availability line on narrow screens to avoid squeezing the drive name.

No automatic scan scheduler, new import workflow, cloud backup feature or destructive account actions are represented as working controls.

Validation: browser checks at 393 px and 320 px, Twilight and Liquid Glass checks, dedicated settings links, Files & drives without a back arrow, saved theme label, and removal of the undated-watches row. Connected Trakt review is covered by existing backend tests and new pure presentation tests; no owner sync scan or apply was performed during UI verification.
