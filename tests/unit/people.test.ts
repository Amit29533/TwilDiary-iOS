import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { personMetadata } from '../../src/lib/server/metadata-person.ts';
import { personSections, personFilmography, personFilmographyPath } from '../../src/lib/people.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { GET } from '../../src/routes/api/metadata/person/+server.ts';
import { d1Fixture } from '../helpers/d1.ts';
import { load as filmographyRoute } from '../../src/routes/preview/person/[id]/[section]/+page.ts';

const personFixture = () => ({
  id: 42,
  name: 'Actor Name',
  biography: 'Provider biography.',
  birthday: '1973-02-11',
  deathday: null,
  place_of_birth: 'Seoul',
  known_for_department: 'Acting',
  profile_path: '/actor.jpg',
  also_known_as: ['Alias', 'Alias', 42],
  combined_credits: {
    cast: [
      {
        id: 10,
        media_type: 'tv',
        name: 'The Show',
        character: 'Lead',
        first_air_date: '2022-01-01',
        vote_count: 100,
        popularity: 42
      },
      { id: 10, media_type: 'tv', name: 'The Show', character: 'Second role' },
      {
        id: 10,
        media_type: 'movie',
        title: 'The Movie',
        character: 'Hero',
        release_date: '2023-01-01',
        poster_path: 'https://bad.example/image.jpg',
        vote_average: 8.5,
        vote_count: 200,
        popularity: 50
      },
      { id: 11, media_type: 'tv', name: 'Adult show', adult: true },
      { id: 12, media_type: 'person', name: 'Not a title' },
      null,
      { id: -1, media_type: 'movie', title: 'Invalid' }
    ],
    crew: [{ id: 10, media_type: 'movie', title: 'The Movie', job: 'Producer' }]
  }
});

test('person metadata validates combined credits, keeps movie/TV identities separate and merges roles', async () => {
  const client = createTmdb('fixture-token', async (input) => {
    const url = new URL(String(input));
    assert.equal(url.pathname, '/3/person/42');
    assert.equal(url.searchParams.get('append_to_response'), 'combined_credits');
    return Response.json(personFixture());
  });
  const person = await client.person(42);
  assert.equal(person.name, 'Actor Name');
  assert.equal(person.birthday, '1973-02-11');
  assert.deepEqual(person.aliases, ['Alias']);
  assert.equal(person.credits.length, 2);
  assert.equal(person.credits[0]!.character, 'Lead / Second role');
  assert.equal(person.credits[1]!.job, 'Producer');
  assert.equal(person.credits[1]!.posterPath, null);
  assert.equal(person.credits[1]!.rating, 8.5);
  await assert.rejects(client.person(0), (error) => (error as { status: number }).status === 400);
  const malformed = createTmdb('fixture', async () =>
    Response.json({ ...personFixture(), combined_credits: {} })
  );
  await assert.rejects(malformed.person(42));
});

test('person pages cache biography and filmography, recover stale results and require owner access', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let calls = 0,
    failed = false;
  const client = createTmdb('fixture-token', async () => {
    calls++;
    if (failed) throw new Error('offline');
    return Response.json(personFixture());
  });
  const result = await personMetadata(f.db, '42', client);
  assert.deepEqual(await personMetadata(f.db, 42, client), result);
  assert.equal(calls, 1);
  f.sqlite.exec("UPDATE metadata_people SET fetched_at='2020-01-01T00:00:00Z'");
  failed = true;
  assert.deepEqual(await personMetadata(f.db, 42, client), { ...result, stale: true });
  assert.equal(calls, 2);
  await assert.rejects(personMetadata(f.db, 'https://example.com', client));
  const denied = await GET({
    locals: {},
    url: new URL('https://diary.test/api/metadata/person?id=42')
  } as never);
  assert.equal(denied.status, 401);
});

test('person shelves include only matching confirmed disk copies and retain the full separate filmographies', async () => {
  const person = await createTmdb('fixture', async () => Response.json(personFixture())).person(42);
  const snapshot = sampleDiary();
  const first = snapshot.titles[0]!;
  snapshot.titles = [
    { ...first, id: 'show', category: 'show', tmdbId: 10 },
    { ...first, id: 'film', category: 'movie', tmdbId: 10 }
  ];
  snapshot.locations = [
    { ...snapshot.locations[0]!, titleId: 'show', evidence: 'present' },
    { ...snapshot.locations[0]!, titleId: 'film', evidence: 'missing' }
  ];
  let shelves = personSections(person, snapshot);
  assert.equal(shelves.localShows.length, 1);
  assert.equal(shelves.localMovies.length, 0);
  assert.equal(shelves.movies.length, 1);
  assert.equal(shelves.shows.length, 1);
  assert.equal(shelves.knownFor[0]!.name, 'The Movie');
  snapshot.locations[0]!.evidence = 'unavailable';
  shelves = personSections(person, snapshot);
  assert.equal(shelves.localShows.length, 0);
});

test('person filmography retains a long list and filters/sorts the full set before vertical paging', async () => {
  const person = await createTmdb('fixture', async () => Response.json(personFixture())).person(42);
  const source = person.credits[1]!;
  person.credits = Array.from({ length: 95 }, (_, i) => ({
    ...source,
    id: i + 1,
    name: `Film ${String(i).padStart(2, '0')}`,
    year: 2020 + (i % 4),
    popularity: i,
    rating: 1 + (i % 10),
    genres: [i % 2 ? 'Drama' : 'Comedy']
  }));
  person.credits.push({ ...person.credits[0]!, mediaType: 'tv', name: 'A show' });
  const snapshot = sampleDiary();
  const all = personFilmography(person, snapshot, 'movies', new URLSearchParams('sort=popular'));
  assert.equal(all.heading, 'Actor Name’s Movies');
  assert.equal(all.items.length, 95);
  assert.equal(all.items[0]!.popularity, 94);
  assert.equal(all.items.slice(0, 40).length, 40);
  assert.equal(all.items.slice(40, 80).length, 40);
  assert.equal(all.items.slice(80).length, 15);
  const filtered = personFilmography(
    person,
    snapshot,
    'movies',
    new URLSearchParams('genre=Drama&year=2023&minimum=7&sort=title&q=Film')
  );
  assert.ok(filtered.items.length);
  assert.ok(
    filtered.items.every(
      (item) => item.genres.includes('Drama') && item.year === 2023 && item.rating! >= 7
    )
  );
  assert.deepEqual(
    filtered.items.map((item) => item.name),
    filtered.items.map((item) => item.name).sort()
  );
  assert.deepEqual(
    personFilmography(person, snapshot, 'shows', new URLSearchParams()).items.map(
      (item) => item.name
    ),
    ['A show']
  );
  assert.ok(
    personFilmography(person, snapshot, 'shows', new URLSearchParams('year=bad')).filters.error
  );
  assert.equal(
    personFilmography(person, snapshot, 'movies', new URLSearchParams('scope=server')).items.length,
    0
  );
  assert.equal(personFilmographyPath(42, 'movies'), '/preview/person/42/movies');
  assert.equal(personFilmographyPath(42, 'shows', true), '/preview/person/42/shows?scope=server');
  for (const section of ['movies', 'shows'])
    assert.equal(
      (await filmographyRoute({ params: { id: '42', section } } as never))?.kind,
      section
    );
  assert.throws(() => filmographyRoute({ params: { id: '42', section: 'other' } } as never));
  assert.throws(() => filmographyRoute({ params: { id: 'bad', section: 'movies' } } as never));
});
