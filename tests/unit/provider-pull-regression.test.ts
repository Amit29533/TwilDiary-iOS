import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { addManualTitle, getTitle } from '../../src/lib/server/library.ts';
import { providerIdentities } from '../../src/lib/server/db/schema.ts';
import {
  applyNormalizedProviderSnapshotToDiary,
  normalizeSimklAllItems,
  normalizeWeTrakrCompactRows,
  syncExternalProviderWithDiary
} from '../../src/lib/server/providers.ts';
import { testWebProviderConnection } from '../../src/lib/client/provider-outbox.ts';

for (const provider of ['trakt', 'simkl', 'wetrakr', 'mdblist'] as const) {
  const config = {
    provider,
    enabled: true,
    loggingMethod: 'direct_only' as const,
    clientId: 'fixture-client',
    accessToken: 'fixture-token',
    apiKey: 'fixture-key'
  };
  test(`${provider}: connection testing performs a read and rejects HTTP/protocol failure`, async () => {
    for (const status of [401, 403, 429, 503])
      await assert.rejects(
        testWebProviderConnection(config, async () => new Response('{}', { status })),
        new RegExp(String(status))
      );
    await assert.rejects(
      testWebProviderConnection(config, async () => Response.json({ ok: true }))
    );
    let calls = 0;
    const transport: typeof fetch = async (_url, init) => {
      calls++;
      assert.equal(init?.method, undefined);
      return Response.json(
        provider === 'trakt'
          ? { user: { ids: { uuid: 'fixture' } } }
          : provider === 'simkl'
            ? { all: null }
            : provider === 'wetrakr'
              ? { movies: { all: null } }
              : { ratings: [] }
      );
    };
    await testWebProviderConnection(config, transport);
    assert.equal(calls, 1);
  });
}
test('Simkl import requests full episode dates and rejects an unknown envelope before writing', async () => {
  const f = d1Fixture();
  try {
    let url = '';
    const transport: typeof fetch = async (input) => {
      url = String(input);
      return Response.json({ unexpected: [] });
    };
    await assert.rejects(
      syncExternalProviderWithDiary(
        f.db,
        'simkl',
        { clientId: 'fixture', accessToken: 'fixture' },
        transport
      ),
      { status: 502 }
    );
    assert.match(url, /episode_watched_at=yes/);
    assert.match(url, /include_all_episodes=yes/);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
  } finally {
    f.close();
  }
});
test('WeTrakr refuses a full unpaginated list and unknown envelopes before applying any rows', async () => {
  for (const body of [{ items: [] }, Array.from({ length: 1000 }, () => ({ ids: { tmdb: 1 } }))]) {
    const f = d1Fixture();
    try {
      await assert.rejects(
        syncExternalProviderWithDiary(
          f.db,
          'wetrakr',
          { clientId: 'fixture', accessToken: 'fixture' },
          async (url) => {
            assert.match(String(url), /compact=true&limit=1000/);
            return Response.json(body);
          }
        ),
        { status: 502 }
      );
      assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM watch_events').get()!.n, 0);
    } finally {
      f.close();
    }
  }
});
test('providers without an import adapter cannot return a false successful zero-row sync', async () => {
  const f = d1Fixture();
  try {
    for (const provider of ['trakt', 'mdblist'] as const)
      await assert.rejects(syncExternalProviderWithDiary(f.db, provider, {}), { status: 400 });
  } finally {
    f.close();
  }
});
test('missing provider dates stay undated instead of borrowing show timestamps or inventing January dates', () => {
  const simkl = normalizeSimklAllItems({
    movies: [{ movie: { ids: { tmdb: 1 } }, status: 'completed' }],
    shows: [
      {
        show: { ids: { tmdb: 2 } },
        last_watched_at: '2026-10-01T12:00:00Z',
        seasons: [{ number: 1, episodes: [{ number: 1 }] }]
      }
    ]
  });
  assert.deepEqual(
    simkl.plays.map((play) => play.watchedAt),
    [null, null]
  );
  assert.equal(
    normalizeWeTrakrCompactRows({ watchedMovies: [{ ids: { tmdb: 1 } }] }).plays[0]!.watchedAt,
    null
  );
});
test('provider import surfaces storage failure and preserves existing local rating choices', async () => {
  const f = d1Fixture();
  try {
    await addManualTitle(f.db, { id: 'fixture', name: 'Synthetic', category: 'movie', year: 2020 });
    await f.db
      .insert(providerIdentities)
      .values({
        id: 'identity',
        titleId: 'fixture',
        provider: 'tmdb',
        kind: 'movie',
        externalId: '1'
      });
    const snapshot = {
      provider: 'simkl' as const,
      plays: [],
      watchlist: [],
      ratings: [{ tmdbId: 1, mediaType: 'movie' as const, rating: 9, ratedAt: null }]
    };
    f.sqlite.exec(
      "CREATE TRIGGER fixture_failure BEFORE UPDATE ON titles BEGIN SELECT RAISE(FAIL,'Synthetic storage failure'); END"
    );
    await assert.rejects(applyNormalizedProviderSnapshotToDiary(f.db, snapshot));
    assert.equal((await getTitle(f.db, 'fixture')).score, null);
    f.sqlite.exec('DROP TRIGGER fixture_failure');
    await applyNormalizedProviderSnapshotToDiary(f.db, snapshot);
    await applyNormalizedProviderSnapshotToDiary(f.db, {
      ...snapshot,
      ratings: [{ ...snapshot.ratings[0]!, rating: 7 }]
    });
    assert.equal((await getTitle(f.db, 'fixture')).score, 9);
  } finally {
    f.close();
  }
});
