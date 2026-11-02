# Personal Profile and universal Search

The five root tabs are Home, Library, Glance, Search and Profile. Profile retains the old `more` storage identity so existing startup preferences still work; the removed `stats` startup choice migrates to Profile. Home's Statistics shortcut opens Statistics in the Profile navigation stack with Today selected. Search has its own retained stack/query. Existing theme, tracking, connections, recovery and export settings remain under Profile.

## Profile structure

Profile menu: personal identity row → Statistics → existing live Your diary summary → existing settings. The personal destination hides root tabs and shows an editable name, a tappable avatar, Popular Characters, then Milestones. Uploading is available only through tapping the picture. The system Photos picker grants access to the selected image; there is no broad photo-library permission request. Chosen photos are downsampled, orientation-corrected, centre-cropped to a 512-square JPEG and written atomically to Application Support, with no source photo metadata. Name/avatar choices are local to this device and never change AniList favourites or upload a photo to the diary server. Failed/cancelled photo selection retains the previous avatar.

Popular characters use AniList's community favourites ranking through the existing actor/client and artwork cache, with a one-hour in-memory cache. Unavailable character data has a retry state and custom photos remain usable. Badges are flat SF Symbols and subtle tints, not raster medals. Eleven milestones derive from active history and existing Statistics calculations; rewatch events do not inflate unique title/movie/anime counts. Future-dated and revoked watches and trashed titles are excluded. Undated watches count toward watched-title milestones; hours/streaks require actual dates, and hours require known runtime. Corrections immediately recalculate progress.

## Search reuse and boundaries

Universal title search reuses CatalogSearchView, DiarySearchTools, existing paged diary/online requests, import routes, identity matching and retained query behaviour. Its empty state reads the existing authenticated discovery endpoint's weekly TMDB feed. People use a new authenticated `/api/metadata/people` read endpoint and the existing AniList GraphQL client; provider identity determines native Cast, Character or Voice Actor routes. Adult TMDB people and unsafe artwork paths are rejected. Only voice-performer staff results are labelled Voice actor. History queries open the existing History view with native date filters; Jellyfin searches its saved list and opens existing native cards. Recent queries are bounded and stored locally only on a chosen result, with a Clear action.

Duplicate general search buttons/fields were removed from other root and pushed pages. Dedicated scanner replacement matching and the Trakt change-review text filter remain contextual controls for those transactions; they are not additional global search entry points.

## Verification

Local TypeScript/Svelte check passed with zero errors/warnings, production build passed, and 48 targeted API/discovery/search tests passed. Workflow YAML, Bash/embedded Python and changed Swift grammar were checked. This Windows environment cannot type-check Swift or run iOS UI tests. Native milestone and persistence tests, five new settings UI journeys and representative Home/History routes are prepared for Codemagic; compact/large phone checks repeat menu, large text and Search journeys. New application version is 2.0.0 (66). Native and physical-device acceptance is pending until evidence is retained.
