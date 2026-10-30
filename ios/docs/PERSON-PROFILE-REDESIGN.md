# Shared Person profiles — 31 October 2026

The owner approved a Home-sized hero and shared visual hierarchy for native cast,
character and voice actor pages. Only the name uses the selected theme accent.
All body text, More, favourite and website icons use neutral white/grey; source
logos retain their brand. Normal source buttons have no live glass effect.

PersonProfilePage owns the near-square photo, readable scrim, name/native name,
role and system toolbar. The favourite stays top-right and uses the existing
FavouritesStore kind/ref identity, optimistic persistence and rollback. The
compact identity reuses the title page's quantized scroll state; credit cells do
not observe per-frame progress. Native Back/interactive-pop ownership is unchanged.
Long names and accessibility text expand the hero; chips wrap instead of overlap.

Cast retains birthday, birthplace, aliases/death date if available, role-in-title,
biography, server shelves and all existing credit destinations. The TMDB logo is
source attribution on a page that already is the native TMDB profile.
Characters retain birthday/age/gender, blood type/aliases/favourites, description,
Voiced by and independently navigable appearances. No real-person TMDB identity
or missing birthday/year is fabricated for a character.
Voice actors retain birthday, hometown, agency, career/favourites, biography,
source and social icons. Their TMDB action continues using the existing verified
AniList/TMDB identity bridge and native PersonRoute. Portrait/name opens Character;
anime caption opens the diary/catalog title using the existing coordinator. A
persisted grid/list control and progressive 30-role batches preserve those actions.

Standalone Markdown link lists become accessible icon buttons, using monochrome
X, Instagram, YouTube and AniList vectors, plus profile/globe system icons for
agency/official sites. Inline prose links stay in the biography with neutral tint.
Only http/https sites are eligible for website buttons. Full-description spoiler
sanitization precedes line splitting. Dates keep partial birthdays without a year;
English Gregorian month names avoid the old M02/M05 display artifacts.

Verification is a focused Codemagic simulator/device gate, not the full suite.
Build screenshots and provenance are required before claiming runtime acceptance.
