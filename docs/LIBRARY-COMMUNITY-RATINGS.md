# Library community ratings

Library grid, list and genre shelves display public scores rather than the diary's personal `score`. TMDB is the default. More → Library → Library ratings provides a native TMDB / Trakt selector, saved on this device and synchronized between tabs. Personal ratings and editing remain unchanged.

TMDB uses the existing imported `communityScore`. Trakt uses only public catalog reads, with no user OAuth token: a saved Trakt ID uses the title ratings endpoint; otherwise the saved TMDB identity is resolved through Trakt's extended ID lookup. Media type and TMDB ID must match. Unmatched, unrated and unavailable scores never fall back to personal ratings or another provider.

`/api/library/ratings` requires the existing owner session, accepts at most 24 saved title IDs and limits upstream concurrency to four. Provider credentials remain on the server. Successful results are cached for a day, failures for a minute; concurrent reads are coalesced. The client keeps a session cache and isolates late responses from changes to the selected source. No diary records or watch history are written.

Highest rating sorting follows the selected provider; missing scores sort last. Badges use a compact dark translucent pill at the poster's upper left, a yellow star, light score text and a readability shadow. Scores have one decimal place. Source names appear in Settings and accessible descriptions, not alongside each badge.

Verified public TMDB and Trakt scores against the running Wi-Fi app, preference persistence after reload, grid/list/genre views and 320px layout. Unit tests cover provider provenance, matching, caching, batching, failures, source persistence and late-response isolation. Reference screenshots are in `docs/screenshots/library-community-ratings-phone.png` and `settings-library-ratings-phone.png`.
