# Home media shelves — 31 October 2026

Owner-approved scope starts at **Up next**. Keep the hero, header, continuation
controls, Explore/Canvas, weekly panel and root navigation unchanged.

## Presentation and wiring

- Up next: normal 2:3 cached posters with aligned two-line names and runtime,
  horizontal lazy shelf, existing planned source order and title destinations.
- Favourites: matching portrait shelf, small theme heart, category caption.
  Reuses FavouriteLink's existing distinct TMDB person / AniList character /
  AniList staff routes and FavouritesStore. Collection and ranking screens keep
  their existing modes; the new presentation is explicitly Home-only.
- New episodes and Recently watched: one HomeEpisodeCard for both landscape
  cards and compact rows, equal artwork ratios, spacing, corners and date
  alignment. Horizontal card shelf replaces Home's two-column grid only.
  Existing independent upcomingGrid/homeHistoryGrid preferences remain valid;
  the accessible state is now Cards/List. No default preference is overwritten.
- Upcoming still opens SavedTitleRoute with the selected episode's season and
  episode focus. History retains ordinary title navigation, event IDs, order,
  rewatch labels and actual watch dates; unknown dates remain unknown.
- History no longer calculates/draws repeated season progress bars. Repeated
  watches do not register duplicate title zoom sources. All history stays on
  the existing full History page; no changes there. Glance and Planned links,
  empty state, progressive upcoming limit and show-more action are retained.
- Reuses Artwork's cache. No metadata fetch on a card tap or layout switch;
  unwatched episode stills are not introduced. Existing projection cache and
  data/network/backend contracts are unchanged. Accessibility text sizes move
  trailing dates below the title instead of squeezing them against its name.

## Scope evidence against 59b4649

Normalized source regions compared exactly before native CI:

| Preserved region | SHA256 |
| --- | --- |
| Home start through just before Up next | 164ba0a9c8e5cd89f234b6fb1ddce2ab39dfcca22feb118f1358e1178bdae31a |
| Home scroll/refresh, header, hero, shortcuts and shared heading helpers | 95b6b856415ef46f8d2874b30552d74b6ce634e44ca4eae5d05a39f0c7487374 |
| Weekly panel, metrics, pull effect and QueueView | 33c53e23004a85962311c1db869fb509f5c41f6d3b98893304295e1e1df48e07 |

## Focused native gate

Codemagic workflow native-ios-home-check runs the core Home golden case,
HomeMediaCardsTests (4 cases), DashboardProjectionTests (4), and six UI journeys:
new lower-Home cards/lists/persistence, existing linked-season navigation,
continuation swipe/restore, upper-Home Stats shortcut, empty diary and the
existing Favourites collection/navigation regression. Package a device IPA only
after successful tests and simulator/device builds with zero warnings. Export
real simulator screenshots and exact source/run/SHA256 provenance.

New unit cases cover title artwork without episode stills, Today/Tomorrow/future
dates, separate rewatch event identities and unknown watch dates. New UI journey
checks poster dimensions, typed favourite navigation, independent card/list
states, season focus, history navigation and process relaunch restoration.

Native execution and visual evidence are pending until the candidate run passes.
Windows has no Xcode; source comparisons are not a substitute for that execution.
No full-suite, alternate-phone-size or physical-device performance claim.
No backend change, live data mutation, main merge, signing or new PR.
