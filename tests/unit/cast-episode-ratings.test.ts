import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTmdb } from '../../src/lib/server/tmdb.ts';
import { castMetadata } from '../../src/lib/server/metadata-cast.ts';
import { importTmdb, loadTmdbSeason } from '../../src/lib/server/metadata-import.ts';
import { seasonPage, patchTitle, logWatch } from '../../src/lib/server/library.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import { GET as castRoute } from '../../src/routes/api/metadata/cast/+server.ts';
import { d1Fixture } from '../helpers/d1.ts';
const json = (value: unknown) => Response.json(value);

test('movie and aggregate TV cast are bounded, deduplicated, and accept only TMDB image paths', async () => {
  const requests: string[] = [];
  const metadata = createTmdb('fixture-token', async (input) => {
    requests.push(new URL(String(input)).pathname);
    return json({
      cast: [
        {
          id: 1,
          name: 'Actor One',
          profile_path: '/portrait.jpg',
          character: 'Movie role',
          roles: [
            { character: 'Guest', episode_count: 1 },
            { character: 'Lead', episode_count: 12 }
          ]
        },
        { id: 1, name: 'Duplicate' },
        {
          id: 2,
          name: 'Actor Two',
          profile_path: 'https://untrusted.example/a.jpg',
          roles: [{ character: 'Series role', episode_count: 10 }]
        },
        null,
        { id: -1, name: 'Invalid' },
        ...Array.from({ length: 30 }, (_, i) => ({ id: i + 3, name: `Actor ${i + 3}` }))
      ]
    });
  });
  const movie = await metadata.cast('movie', 42);
  const tv = await metadata.cast('tv', 42);
  assert.equal(movie.length, 24);
  assert.equal(tv[1]!.character, 'Series role');
  assert.equal(tv[1]!.profilePath, null);
  assert.equal(movie[0]!.profilePath, '/portrait.jpg');
  assert.deepEqual(requests, ['/3/movie/42/credits', '/3/tv/42/aggregate_credits']);
  await assert.rejects(metadata.cast('tv', 0));
});

test('credits cache avoids repeat upstream requests, survives outages, and requires owner access', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let calls = 0,
    failed = false;
  const metadata = createTmdb('fixture', async () => {
    calls++;
    if (failed) throw new Error('provider unavailable');
    return json({ cast: [{ id: 1, name: 'Actor', character: 'Character' }] });
  });
  const params = new URLSearchParams('type=tv&id=42');
  const first = await castMetadata(f.db, params, metadata);
  assert.equal(first.cast[0]!.name, 'Actor');
  assert.deepEqual(await castMetadata(f.db, params, metadata), first);
  assert.equal(calls, 1);
  f.sqlite.exec("UPDATE metadata_credits SET fetched_at='2020-01-01T00:00:00Z'");
  failed = true;
  const stale = await castMetadata(f.db, params, metadata);
  assert.equal(stale.stale, true);
  assert.equal(stale.cast[0]!.name, 'Actor');
  assert.equal(calls, 2);
  const denied = await castRoute({
    locals: {},
    url: new URL('https://diary.test/api/metadata/cast?type=tv&id=42')
  } as never);
  assert.equal(denied.status, 401);
});

test('episode community scores upgrade cached metadata without changing watches, notes or spoiler protection', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  let seasons = 0;
  const metadata = createTmdb('fixture', async (input) => {
    if (String(input).includes('/season/')) {
      seasons++;
      return json({
        season_number: 1,
        episodes: [8.7, 0, 12].map((score, i) => ({
          id: 100 + i,
          season_number: 1,
          episode_number: i + 1,
          name: 'Spoiler',
          overview: 'Secret plot',
          air_date: '2020-01-01',
          vote_average: score,
          vote_count: i === 1 ? 0 : 25,
          still_path: '/still.jpg'
        }))
      });
    }
    return json({
      id: 42,
      name: 'Show',
      first_air_date: '2020-01-01',
      genres: [],
      seasons: [{ season_number: 1, name: 'Season 1', episode_count: 3 }]
    });
  });
  const { title } = await importTmdb(f.db, metadata, {
    mediaType: 'tv',
    tmdbId: 42,
    category: 'show'
  });
  await patchTitle(f.db, title.id, { expectedVersion: 1, notes: 'Keep my notes' });
  await loadTmdbSeason(f.db, metadata, title.id, 1);
  let page = await seasonPage(f.db, title.id, 1);
  assert.equal(page.items[0]!.communityScore, 8.7);
  assert.equal(page.items[0]!.name, null);
  assert.equal(page.items[0]!.overview, null);
  assert.equal(page.items[0]!.stillPath, null);
  assert.equal(page.items[1]!.communityScore, null);
  assert.equal(page.items[2]!.communityScore, null);
  await logWatch(f.db, title.id, {
    operationId: 'rating-watch-1',
    episodeId: page.items[0]!.id,
    watchedAt: '2020-01-02T00:00:00.000Z'
  });
  await loadTmdbSeason(f.db, metadata, title.id, 1);
  assert.equal(seasons, 1, 'fresh versioned metadata reuses the cache');
  f.sqlite.exec('UPDATE seasons SET metadata_version=1');
  await loadTmdbSeason(f.db, metadata, title.id, 1);
  assert.equal(
    seasons,
    2,
    'older metadata receives episode scores despite a recent cache timestamp'
  );
  page = await seasonPage(f.db, title.id, 1);
  assert.equal(page.progress.watched, 1);
  assert.equal(f.sqlite.prepare('SELECT notes FROM titles').get()!.notes, 'Keep my notes');
  const workspace = await workspacePage(f.db, new URLSearchParams('section=episodes'));
  const episode = workspace.items[0];
  assert.ok(episode && 'communityScore' in episode);
  assert.equal(episode.communityScore, 8.7);
  const library = await workspacePage(f.db, new URLSearchParams('section=titles'));
  const saved = library.items[0];
  assert.ok(saved && 'tmdbId' in saved);
  assert.equal(saved.tmdbId, 42);
});
