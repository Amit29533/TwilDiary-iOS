# Profile formatting and public-profile audit

Audited 31 October 2026: eight AniList characters, six AniList staff profiles and
eight TMDB person pages. Four voice actors were compared on both providers.
AniList public GraphQL supplied the exact data/description format. TMDB pages
were inspected in the browser; no diary or hosted data was changed.

## Findings and presentation contract

- Share layout and typography; preserve provider-specific fields and identities.
- Native name only when supplied as native, never the first translated alias.
- Birthdays may be complete, month/day, month/year, year-only or absent. Keep
  precision; no invented day/year. Character ages are supplied strings (ranges,
  qualifiers and 1000+); do not calculate fictional ages from today's date.
- Human age can be calculated only from a complete birth date, stopping at death.
- Two equal-width/equal-height short-fact cards; long locations span full width.
  Accessibility text and narrow content use one column. Values wrap uncut. An
  unpaired short fact fills its row rather than leaving an empty half-column.
- Keep aliases deduplicated and independently expandable, excluding displayed names.
- Explicit standalone description fields become facts/supplemental labelled text;
  unknown/conflicting/long fields stay in prose. Spoiler removal precedes parsing.
- External website icons have their own Links section. Standalone native references
  use neutral text links in a separate related-links group. Inline references stay
  in prose and route through the existing AnimeNavigationLookup/provider routes.
- Preserve paragraphs, bullet lists and role lists. More/Less only when the preview
  actually overflows. No blue text or Liquid Glass fact cards.
- Small source action beside the role: native TMDB credits for Cast, native person
  lookup for voice actor, AniList identity for character. Website icons stay below.
- Saved history defines Watched. Credit ratings retain their provider; missing
  ratings never become fabricated zero scores. Portrait/credit captions wrap.
- At accessibility sizes, narrow poster shelves and voice-role grids become
  full-width rows, keeping long names readable. Source/heart actions remain
  available; the compact backdrop covers only the safe navigation area.
- Existing server response does not expose TMDB's external/social IDs or stage-name
  field. Do not invent them or scrape the website in the app. The Cast layout uses
  available API fields and its existing native TMDB action.

## Validation scope

`catalog-profile-format-matrix.json` retains factual fields and observed metadata/
link formats from 22 public profiles. Narrative biography prose is synthetic,
clearly labelled in the fixture, to test overflow without republishing biographies.
The fixture and loaders are DEBUG-only; catalog-*.json resources are excluded from
Release. Native tests check four format journeys on iPhone 17 Pro, 17e and 17 Pro
Max, including accessibility XXXL text. Lookup/navigation/Home tests are targeted,
not a whole-suite regression. Compilation and native execution pending for this
candidate; no claim of physical-device verification.

## Sample sources

- character: [Kurumi Tokisaki](https://anilist.co/character/70069)
- character: [Shinobu Kochou](https://anilist.co/character/136070)
- character: [Frieren](https://anilist.co/character/176754)
- character: [Anya Forger](https://anilist.co/character/138100)
- character: [Violet Evergarden](https://anilist.co/character/90169)
- character: [Lelouch Lamperouge](https://anilist.co/character/417)
- character: [Alphonse Elric](https://anilist.co/character/12)
- character: [Holo](https://anilist.co/character/7373)
- voice: [Saori Hayami](https://anilist.co/staff/95869)
- voice: [Rina Hidaka](https://anilist.co/staff/100250)
- voice: [Rie Takahashi](https://anilist.co/staff/119331)
- voice: [Asami Seto](https://anilist.co/staff/106787)
- voice: [Kana Ichinose](https://anilist.co/staff/124390)
- voice: [Mamoru Miyano](https://anilist.co/staff/95065)
- cast: [Saori Hayami](https://www.themoviedb.org/person/221773)
- cast: [Rina Hidaka](https://www.themoviedb.org/person/1116334)
- cast: [Rie Takahashi](https://www.themoviedb.org/person/1492982)
- cast: [Asami Seto](https://www.themoviedb.org/person/1254672)
- cast: [Jenna Ortega](https://www.themoviedb.org/person/974169-jenna-ortega)
- cast: [Park Eun-bin](https://www.themoviedb.org/person/1134684)
- cast: [Keanu Reeves](https://www.themoviedb.org/person/6384-keanu-reeves)
- cast: [Chadwick Boseman](https://www.themoviedb.org/person/172069-chadwick-boseman)
