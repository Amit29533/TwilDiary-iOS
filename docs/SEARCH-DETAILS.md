# Search → title details

Search on Home, Library and the shared diary header now opens saved titles directly in the existing episode/detail screen. Online results open `/diary/discover/{movie|tv}/{tmdbId}` without importing anything. Explore uses the same route. Movie and TV identities stay separate, including identical numeric TMDb IDs.

The online screen includes artwork, overview, TMDb score and, for shows, a native season selector beside Episodes and an episode list. Episode titles, stills and synopses are redacted by the server until explicitly revealed. Tapping a row reveals its details; the others remain visually hidden. The redesigned UI initially shows four ordered episode rows and offers Show all for longer seasons; saved shows anchor that preview around the next episode. Requests cancel when the title or season changes.

“Add to Planned” explicitly imports the title and opens its saved diary screen. Existing identities redirect to their saved screen; trashed titles offer Restore from Trash. Browsing does not create titles or watch events. The scanner's intentional match/import picker remains unchanged.

Verification: `npm run verify` passed 182 unit/API/domain tests, 3 service-worker tests, Svelte/TypeScript checks (zero errors/warnings) and the Cloudflare Workers build. New disposable SQLite tests cover read-only browsing, identity separation, Trash detection, spoiler redaction, invalid season inputs and owner-only API access. Live local browser checks confirmed Home search → online episodes and per-row spoiler reveal without adding a title. No Git commit, push or deployment was made for this increment.
