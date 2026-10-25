# Glance reference controls and episode line

The supplied G1/G2 references guide the requested top category bar and card metadata. Glance now has compact underlined All / Movies / Shows / Anime tabs, matching Library. The PC-only button/filter and card PC indicators are removed. Old saved `onlyPC` state is ignored, so it cannot silently hide current watches. Search and category state still participate in page memory.

Cards remove the heart and season dropdown. The next regular season is chosen automatically from unwatched episodes or incomplete season metadata. Specials cannot become the default. Known future episodes remain unavailable to the watch button until aired. Title details still provide full season controls; card overflow menus, watch/unwatch commands, existing progress bars and poster dimensions remain intact.

The new metadata line uses `S1 · E11 of 16 · 4h 40m left`, with a light remaining-time segment and dark text shadow for legibility over bright artwork. It counts distinct watched episodes in the active season and multiplies remaining episodes by known per-episode runtime. The label is an estimate; incomplete TMDB catalogues or absent runtimes show Time unknown. A known fully watched season has zero time remaining. Movie cards show Movie with their remaining runtime, switching to zero once an active viewing is recorded. The existing time/progress bar is retained. No sorting menu or waiting-section behavior is added.

Calculation tests cover the reference numbers, rewatches, revoked logs, foreign-title references, specials, partial/missing metadata and runtimes, future episodes, skipped next episodes, automatic season transitions and movies. No migrations or owner-history writes are required. Browser/device visual automation is unavailable; native iPhone appearance remains for physical review.


## Swipe to log one watch

Touch/pen users can swipe a Glance card right past a deliberate threshold and release to log exactly its captured next episode (or one unwatched movie). Green feedback indicates when release will log. The same diary watch command provides the existing Undo toast and server-side status/idempotency behavior. The plus/minus buttons remain available.

Vertical scroll, pinch, left swipes, screen-edge back gestures, controls and open menus never commit a watch. Pointer cancel, scroll, blur and artwork context menus reset the gesture. A short release-click guard prevents a swipe from also opening its title, even if completing a movie/show removes that card. New pointer presses and keyboard actions clear the guard immediately; it also expires after 650ms.

The card stays clipped during both the drag and slide-back animation, preventing temporary horizontal document overflow from moving the viewport after release. Open title menus can extend beyond the card when no swipe is active. The resting foreground has no transform, preserving the existing native history snapshot behavior.

Gesture tests exercise the shipped action with pointer events, captured-target updates, single commits, cancellation, controls, back-edge protection, multi-touch, release clicks, fresh-tap recovery and teardown. Phone swipe behavior still requires physical-device confirmation.
