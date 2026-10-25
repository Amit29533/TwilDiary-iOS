import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  exploreSections,
  exploreSection,
  exploreSectionPath,
  exploreSectionFilters,
  filterExploreSection,
  mergeSectionPage
} from '../../src/lib/explore-sections.ts';
import type { DiscoveryItem, DiscoveryPage } from '../../src/lib/discovery.ts';

const base: DiscoveryItem = {
  id: 1,
  mediaType: 'tv',
  name: 'Zulu',
  year: 2020,
  overview: '',
  posterPath: null,
  backdropPath: null,
  rating: 8,
  votes: 200,
  genres: ['Drama'],
  source: 'tmdb'
};

test('every Explore section has a dedicated destination with preserved genre filters', () => {
  assert.equal(exploreSections.length, 7);
  for (const section of exploreSections)
    assert.equal(exploreSectionPath(section.key), `/preview/explore/${section.key}`);
  const url = new URL(
    exploreSectionPath('genres', {
      type: 'movie',
      genre: 'Sci-fi & fantasy',
      sort: 'rating',
      year: '2020',
      minimum: '8'
    }),
    'https://diary.test'
  );
  assert.equal(url.searchParams.get('genre'), 'Sci-fi & fantasy');
  const filters = exploreSectionFilters(exploreSection('genres')!, url.searchParams);
  assert.equal(filters.type, 'movie');
  assert.equal(filters.sort, 'rating');
  assert.equal(filters.year, '2020');
  assert.equal(filters.minimum, 8);
  assert.equal(filters.error, '');
  assert.equal(exploreSection('not-a-section'), undefined);
  assert.throws(() => exploreSectionPath('../more'));
});

test('fixed section types cannot turn shows into movies and invalid filters cannot query providers', () => {
  const shows = exploreSection('rated-shows')!;
  assert.equal(exploreSectionFilters(shows, new URLSearchParams('type=movie')).type, 'tv');
  assert.equal(
    exploreSectionFilters(exploreSection('popular-movies')!, new URLSearchParams('type=tv')).type,
    'movie'
  );
  assert.equal(exploreSectionFilters(shows, new URLSearchParams()).sort, 'rating');
  assert.equal(exploreSectionFilters(shows, new URLSearchParams('sort=title')).sort, 'rating');
  for (const query of ['year=2', 'year=2300', 'minimum=11', 'minimum=NaN', 'genre=Invented'])
    assert.ok(exploreSectionFilters(shows, new URLSearchParams(query)).error);
  assert.equal(
    exploreSectionFilters(exploreSection('daily')!, new URLSearchParams('genre=Fantasy&sort=title'))
      .error,
    '',
    'Library genres do not need to match TMDB genre names'
  );
});

test('recommendation pages intersect media, genre, year and ratings and sort the complete local set', () => {
  const items = [
    base,
    { ...base, id: 2, name: 'Alpha', rating: 9 },
    { ...base, id: 3, mediaType: 'movie' as const },
    { ...base, id: 4, rating: null },
    { ...base, id: 5, year: 2024 }
  ];
  const filters = exploreSectionFilters(
    exploreSection('recommended')!,
    new URLSearchParams('type=tv&genre=Drama&year=2020&minimum=8&sort=title')
  );
  assert.deepEqual(
    filterExploreSection(items, filters).map((item) => item.id),
    [2, 1]
  );
  assert.deepEqual(
    filterExploreSection(items, { ...filters, sort: 'rating' }).map((item) => item.id),
    [2, 1]
  );
  assert.equal(items[0]!.name, 'Zulu');
});

test('Load more keeps provider ordering, removes overlaps and preserves movie/TV identity', () => {
  const first: DiscoveryPage = { source: 'tmdb', page: 1, totalPages: 3, items: [base] };
  const next: DiscoveryPage = {
    ...first,
    page: 2,
    items: [base, { ...base, id: 2 }, { ...base, mediaType: 'movie' }]
  };
  const merged = mergeSectionPage(first, next);
  assert.equal(merged.page, 2);
  assert.equal(merged.totalPages, 3);
  assert.deepEqual(
    merged.items.map((item) => `${item.mediaType}:${item.id}`),
    ['tv:1', 'tv:2', 'movie:1']
  );
  assert.deepEqual(mergeSectionPage(merged, next).items, merged.items);
  assert.equal(first.items.length, 1);
  assert.equal(
    mergeSectionPage(null, next).items.length,
    3,
    'Changing filters starts a new collection'
  );
});
