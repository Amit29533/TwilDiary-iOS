import type { DiscoveryItem } from './discovery.ts';
import type { DiarySnapshot } from './domain/types.ts';
import { isSeries } from './domain/types.ts';
import { exploreSectionFilters, filterExploreSection } from './explore-sections.ts';

export interface PersonCredit extends DiscoveryItem {
  character: string;
  job: string;
  popularity: number;
  episodeCount: number | null;
}
export interface PersonDetails {
  id: number;
  name: string;
  biography: string;
  birthday: string | null;
  deathday: string | null;
  birthplace: string;
  department: string;
  profilePath: string | null;
  aliases: string[];
  credits: PersonCredit[];
}

export type FilmographyKind = 'shows' | 'movies' | 'known-for' | 'credits';
export function personFilmographyPath(id: number, kind: FilmographyKind, server = false) {
  if (!Number.isSafeInteger(id) || id < 1 || id > 9999999999) throw new Error('Invalid person');
  return `/preview/person/${id}/${kind}${server ? '?scope=server' : ''}`;
}
export function personFilmography(
  person: PersonDetails,
  snapshot: DiarySnapshot,
  kind: FilmographyKind,
  params: Pick<URLSearchParams, 'get'>
) {
  const sections = personSections(person, snapshot);
  const onServer = params.get('scope') === 'server';
  const credits =
    kind === 'known-for'
      ? sections.knownFor
      : kind === 'credits'
        ? onServer
          ? [...sections.localShows, ...sections.localMovies]
          : person.credits
        : kind === 'shows'
          ? onServer
            ? sections.localShows
            : sections.shows
          : onServer
            ? sections.localMovies
            : sections.movies;
  const filters = exploreSectionFilters(
    {
      key: kind,
      label: kind,
      source: 'library',
      type: kind === 'shows' ? 'tv' : kind === 'movies' ? 'movie' : 'all',
      sort: kind === 'known-for' ? 'popular' : 'newest'
    },
    params
  );
  const query = (params.get('q') ?? '').normalize('NFKC').trim().toLocaleLowerCase();
  if (query.length > 200) filters.error = 'Keep search within 200 characters.';
  let items = filterExploreSection(
    credits.filter((item) => item.name.normalize('NFKC').toLocaleLowerCase().includes(query)),
    filters
  ) as PersonCredit[];
  if (filters.sort === 'popular')
    items = items.toSorted(
      (a, b) => b.popularity - a.popularity || b.votes - a.votes || a.name.localeCompare(b.name)
    );
  return {
    heading: `${person.name}’s ${kind === 'shows' ? 'Shows' : kind === 'movies' ? 'Movies' : kind === 'known-for' ? 'Known for' : onServer ? 'Titles on your server' : 'Credits'}`,
    filters,
    query,
    onServer,
    items,
    genres: [...new Set(credits.flatMap((item) => item.genres))].sort()
  };
}

export function personSections(person: PersonDetails, snapshot: DiarySnapshot) {
  const movies = person.credits.filter((item) => item.mediaType === 'movie');
  const shows = person.credits.filter((item) => item.mediaType === 'tv');
  const stored = new Set(
    snapshot.locations
      .filter((location) => location.evidence === 'present')
      .map((location) => location.titleId)
  );
  const onDisk = (item: PersonCredit) =>
    snapshot.titles.some(
      (title) =>
        stored.has(title.id) &&
        title.tmdbId === item.id &&
        isSeries(title) === (item.mediaType === 'tv')
    );
  const popular = person.credits.filter(
    (item) => item.votes >= 20 && !/^self\b/i.test(item.character)
  );
  const prominence = (item: PersonCredit) =>
    item.popularity *
    (item.mediaType === 'tv' && item.episodeCount ? Math.min(1, item.episodeCount / 8) : 1);
  const knownFor = [...(popular.length ? popular : person.credits)]
    .sort((a, b) => prominence(b) - prominence(a) || b.votes - a.votes)
    .slice(0, 12);
  const byYear = (a: PersonCredit, b: PersonCredit) =>
    (b.year ?? 0) - (a.year ?? 0) || a.name.localeCompare(b.name);
  return {
    movies: movies.sort(byYear),
    shows: shows.sort(byYear),
    knownFor,
    localMovies: movies.filter(onDisk),
    localShows: shows.filter(onDisk)
  };
}
