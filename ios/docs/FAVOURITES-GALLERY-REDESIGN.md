# Favourites galleries — 31 October 2026

The owner approved the horizontal Most watched and Hearted-grid design, with
the existing Favourites title/Back and large text category tabs retained. They
explicitly excluded the source caption. No segmented selector or search action
was added. The three categories still use their existing sources and identities.

MostWatchedShelf renders the loaded ranking in its original order, with rank,
portrait, two-line name and title/anime/play counts. Artwork uses the existing
cache. View all pushes PeopleRankingRoute carrying that exact value snapshot,
including full role metadata and typed cast/character/voice destinations. It
makes no ranking request. Backend loading/caching and ranking semantics remain
unchanged. Partial results are labelled in the detailed list/accessibility.

Hearted supports the same three-column portrait geometry in all categories,
plus a row layout. Three existing-style AppStorage preferences are independent
per category. FavouriteLink still owns the correct profile route and the Home
circular variant. Favouriting, persistence, optimistic rollback and native
interactive Back/tab visibility remain owned by the existing components.

RankedPerson distinguishes TMDB person IDs from AniList staff/character IDs.
A diary voice rank carries both the optional resolved staff ID and the known
TMDB ID, preserving name fallback and watch count. View all never substitutes
one provider's integer for another. Character AniList connection remains in
Settings and through a small accessible source-icon action.

Focused verification adds three identity/snapshot unit tests and a fixture-only
UI journey for horizontal scrolling, all-ranks navigation, all profile types,
category layout isolation, original header and absence of source captions.
Candidate compilation/screenshots are required before runtime acceptance.
