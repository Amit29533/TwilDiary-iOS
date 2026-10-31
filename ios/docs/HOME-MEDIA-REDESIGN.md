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
- Reuses Artwork's cache. Cards and layout switches introduce no metadata
  requests; destinations retain their existing loading behavior. Unwatched
  episode stills are not introduced. Existing projection cache and
  data/network/backend contracts are unchanged. Accessibility text sizes move
  trailing dates below the title instead of squeezing them against its name.

## Scope evidence against 59b4649

Initial candidate source regions compared exactly against the baseline:

| Preserved region | SHA256 |
| --- | --- |
| Home start through just before Up next | 164ba0a9c8e5cd89f234b6fb1ddce2ab39dfcca22feb118f1358e1178bdae31a |
| Home scroll/refresh, header, hero, shortcuts and shared heading helpers | 95b6b856415ef46f8d2874b30552d74b6ce634e44ca4eae5d05a39f0c7487374 |
| Weekly panel, metrics, pull effect and QueueView | 33c53e23004a85962311c1db869fb509f5c41f6d3b98893304295e1e1df48e07 |

### Owner geometry comparison follow-up

Normalize the mockup by its usable display rectangle, excluding its decorative
phone frame; the actual simulator is 402 points wide at 3x scale. The mockup's
roughly 739-pixel-wide display maps its 219-pixel thumbnail to about 119 points,
and its 144-pixel row to about 78 points. The first candidate used 80x45 images,
72-point rows, 16-point outer margins and 14-point row corners: visibly different.

Corrected list geometry: responsive 16:9 thumbnails at 30% of viewport width,
capped at 120 points (67.5 tall), 6-point internal padding, 78-point minimum
row height, 12-point outer margins and 12-point row corners. Title/episode use
16/13-point Dynamic Type styles. Remove reserved blank title/caption lines in
portrait shelves. Initial upper content keeps its existing 16-point margins.

The actual scrolled screenshot also exposed an existing transparent-header
overlap with the status area. A Home-only leaf reuses PageHeader in full mode
with an opaque status/header backing once the first lower section reaches it;
the initial hero/header mode remains unchanged. Observe only that boundary's
Boolean crossing, including absent Planned/Favourites sections. No per-frame
state publication to the media/hero tree. Bottom scroll-content margin lets
the last history row fully clear the native floating bar. Native tab geometry
and other app headers are unchanged.

Rechecked initial content/hero/Explore/Canvas/week helpers exactly against the
baseline, allowing only the new lower-scroll header-state reference and overlay.
UI assertions now measure actual row bounds/insets/equal heights, require cards
to clear both headers, and verify the final row is above the native bottom bar.
The mockup's outer hardware bezel is presentation, not an app border to draw.

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

Source 09bec03 passed the six UI journeys and eight native units; its simulator
build had zero warnings. First candidate c95cb69 stopped on incorrectly encoded
test punctuation; all pre-existing UI test text was restored exactly, and the
new Home assertion repaired without weakening it. Geometry follow-up native
execution and visual evidence remain pending until its candidate run passes.
Windows has no Xcode; source comparisons are not a substitute for that execution.
No full-suite, alternate-phone-size or physical-device performance claim.
No backend change, live data mutation, main merge, signing or new PR.
