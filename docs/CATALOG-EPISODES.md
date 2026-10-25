# Catalog episode layout and recovery

Catalog title pages no longer show the redundant Not in library badge in the hero toolbar. The Add to Planned button has no inherited mark-next top margin, keeping its panel padding even. The catalog Episodes heading uses two columns, with the count under the heading and the season selector aligned on the right.

Catalog episode previews start with the first three episodes of the selected season in numeric order. They previously searched the saved library snapshot for Up Next; catalog titles have no matching library identity, so the fallback incorrectly selected the season's last three episodes. Show all and Show fewer retain numeric order. Saved shows retain their existing progress-centered episode window.

Title loading, adding and episode requests have separate error states. Add errors stay with the Add button. Season/episode errors render inside Episodes, with a sticky safe-area-aware Retry control rather than a notice before the negatively offset hero. Retry preserves the failed season and spoiler-reveal intent. Switching seasons clears unrelated rows, aborts obsolete requests and ignores their results. Successfully revealed catalog seasons are reused within the page rather than refetched for every expanded episode.

Saved-library season loading now reports success/failure to the detail screen, which uses the same Episodes retry notice. Failed loads leave the request cache so a retry can succeed; subsequent episode expansions reuse the loaded season. Revealing episode details does not log viewing history.

Validation: episode-window regression tests cover unordered catalog data, initial episodes, expand/collapse, season filtering and saved-show progress windows. Controller regression tests inject a TMDB-style failure, retry successfully, check request reuse and verify watch history is unchanged. Full verification passed 202 unit/database/runtime tests, 3 compiled PWA checks, type checks with zero errors/warnings and the production build. Browser control remains disabled in Work settings; no fresh visual or physical-phone verification is claimed. No owner data, schema, commits or pushes were changed.

Deployed to the existing private Cloudflare app as version `39ec2510-e2af-4bf5-9eb1-36fc4b41bd2c`.
