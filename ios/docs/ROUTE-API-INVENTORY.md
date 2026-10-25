# Web route and API inventory

Generated from actual source at baseline `b43454e`. Legacy redirects are listed alongside product routes; they do not imply separate native screens.

## Screens

| Route | Components |
|---|---|
| `/preview` | EmptyState, GlanceCard, ScreenHeading |
| `/preview/activity` | ScreenHeading, StatsDashboard |
| `/preview/discover/[type]/[id]` | BrandMark, TitleScreen |
| `/preview/explore` | ExploreView, ScreenHeading |
| `/preview/explore/[section]` | BrowseHeading, DiscoveryCard, EmptyState, ScreenHeading |
| `/preview/files` | EmptyState, ScreenHeading |
| `/preview/home` | ContinueCarousel, HistoryList, HomeSections, ScreenHeading |
| `/preview/library` | CollectionConfirm, CollectionSelection, EmptyState, ExploreView, GenreShelves, LibraryControls, MetadataDialog, ScreenHeading, TitleCard |
| `/preview/more` | ScreenHeading, SettingRow, SettingsGroup |
| `/preview/more/about` | BrandMark, ScreenHeading |
| `/preview/more/appearance` | ScreenHeading, ThemePicker |
| `/preview/more/tmdb` | ScreenHeading, TmdbConnection |
| `/preview/more/trakt` | ScreenHeading, TraktConnection |
| `/preview/person/[id]` | BrandMark, MetadataShelf |
| `/preview/person/[id]/[section]` | BrandMark, BrowseHeading, DiscoveryCard, EmptyState, ScreenHeading |
| `/preview/recently-watched` | EmptyState, HistoryList, ScreenHeading |
| `/preview/review` | ScannerReview, ScreenHeading |
| `/preview/title/[id]` | TitleScreen |

## API handlers

| Methods | Route |
|---|---|
| GET | `/api/discovery` |
| GET | `/api/discovery/seeds` |
| GET | `/api/disks` |
| GET | `/api/files` |
| GET | `/api/glance` |
| GET | `/api/glance/[id]` |
| GET | `/api/history` |
| GET | `/api/home` |
| GET | `/api/library/ratings` |
| GET | `/api/metadata/browse` |
| GET | `/api/metadata/cast` |
| POST | `/api/metadata/import` |
| GET | `/api/metadata/person` |
| GET | `/api/metadata/related` |
| GET | `/api/metadata/search` |
| GET | `/api/metadata/season` |
| GET | `/api/metadata/status` |
| GET | `/api/metadata/title` |
| POST | `/api/progress/status` |
| GET | `/api/scanner/review` |
| POST | `/api/scanner/review/[id]/resolve` |
| GET | `/api/search` |
| GET | `/api/session` |
| GET | `/api/stats` |
| GET, POST | `/api/titles` |
| DELETE, GET, PATCH | `/api/titles/[id]` |
| POST | `/api/titles/[id]/restore` |
| GET | `/api/titles/[id]/seasons/[number]` |
| POST | `/api/titles/[id]/seasons/[number]/metadata` |
| POST | `/api/titles/[id]/watches` |
| POST | `/api/titles/bulk` |
| GET | `/api/trakt/callback` |
| POST | `/api/trakt/connect` |
| POST | `/api/trakt/disconnect` |
| GET | `/api/trakt/status` |
| GET, POST | `/api/trakt/sync` |
| POST | `/api/trakt/sync/[id]/apply` |
| POST | `/api/trakt/sync/[id]/cancel` |
| POST | `/api/trakt/sync/[id]/step` |
| DELETE | `/api/trash` |
| PATCH | `/api/watch-events/[id]` |
| GET | `/api/workspace` |
| GET, POST | `/api/workspace/migrate` |
| GET | `/diary/[...legacy]` |
