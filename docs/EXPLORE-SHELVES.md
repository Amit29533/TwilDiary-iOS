# Explore shelves and daily library recommendation

Explore follows this order: Recommendation of the day, Recommended for you, Highest rated shows, Highest rated movies, Popular shows, Popular movies, Browse by genre.

The daily recommendation is derived from the live library workspace, not a public discovery feed. Candidates must be active Planned titles with no active watch events. Watching, Completed, Dropped and trashed titles are excluded, as are Planned titles that still have viewing history. Revoked watches do not exclude a candidate. Candidate IDs are sorted before the date-based choice so changing library display order does not change the pick. If no eligible title exists, Explore shows an empty state with a Library link; it never substitutes an online or watched title. The hero opens the saved title directly and uses its existing cover, backdrop and community score.

Recommended for you retains the existing personal Trakt feed. The four added TMDB shelves scroll horizontally using the app's standard poster geometry. Highest-rated queries sort by community score with at least 200 votes; popular queries use provider popularity with at least 20 votes. Both are separated by movie/TV type and retain the existing adult-content and release-date filters. Each shelf has independent loading/error/Retry state and uses the existing bounded five-minute in-view cache.

Browse by genre comes last. Selecting a genre loads its filtered discoveries; before selection it shows a short prompt instead of duplicating a default popular grid. The Shows/Movies switch, year, minimum score, sort and pagination remain available.

Validation: 206 unit/database/runtime tests, 3 compiled PWA checks, zero Svelte/TypeScript errors/warnings and successful production build. New tests cover daily-pick eligibility, revoked history, empty candidates, stable order and all four provider query configurations. Read-only live local API checks returned 20 items for each of the four shelves. Browser control remains disabled in Work settings, so a fresh visual phone check is pending. No owner data, schema, commits, pushes or Trakt sync changes were made.

Private Cloudflare release: `5cc35fa7-78ff-458d-b599-599aeb151cd2`.
