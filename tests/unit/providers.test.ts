import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildOutboundProviderPayloads,
  changedWeTrakrDomains,
  normalizeMDBListSummary,
  normalizeSimklAllItems,
  normalizeWeTrakrCompactRows,
  parseWeTrakrActivities
} from '../../src/lib/server/providers.ts';
import {
  activeDirectLoggingProviders,
  defaultProviderConnectionSettings,
  hasProviderCredentials,
  isProviderAuthenticated,
  providerStatusBadge,
  readProviderConnectionSettings,
  writeProviderConnectionSettings
} from '../../src/lib/client/provider-settings.ts';

test('normalizeSimklAllItems extracts TMDb plays, ratings, and watchlist across movies, shows, and anime', () => {
  const snapshot = normalizeSimklAllItems({
    movies: [
      {
        status: 'completed',
        last_watched_at: '2026-10-20T10:00:00Z',
        user_rating: 9,
        movie: { ids: { tmdb: '550' } }
      }
    ],
    shows: [
      {
        status: 'watching',
        user_rating: 8,
        show: { ids: { tmdb: 1399 } },
        seasons: [{ number: 1, episodes: [{ number: 1, watched_at: '2026-10-21T12:00:00Z' }] }]
      }
    ],
    anime: [
      {
        status: 'plantowatch',
        added_to_watchlist_at: '2026-10-22T09:00:00Z',
        show: { ids: { tmdb: 209867 } }
      }
    ]
  });

  assert.equal(snapshot.provider, 'simkl');
  assert.equal(snapshot.plays.length, 2);
  assert.deepEqual(snapshot.plays[0], {
    tmdbId: 550,
    mediaType: 'movie',
    watchedAt: '2026-10-20T10:00:00Z'
  });
  assert.deepEqual(snapshot.plays[1], {
    tmdbId: 1399,
    mediaType: 'tv',
    season: 1,
    episode: 1,
    watchedAt: '2026-10-21T12:00:00Z'
  });
  assert.equal(snapshot.ratings.length, 2);
  assert.equal(snapshot.watchlist.length, 1);
  assert.equal(snapshot.watchlist[0]!.tmdbId, 209867);
});

test('normalizeMDBListSummary and buildOutboundProviderPayloads format Simkl and Trakt payloads', () => {
  const summary = normalizeMDBListSummary(
    {
      score: 88,
      ratings: [
        { source: 'imdb', value: 8.9, score: 89, votes: 250000 },
        { source: 'trakt', value: 87, score: 87, votes: 42000 }
      ]
    },
    550,
    'movie'
  );
  assert.equal(summary.score, 88);
  assert.equal(summary.ratings.length, 2);

  const simklPayloads = buildOutboundProviderPayloads('simkl', {
    plays: [{ tmdbId: 1399, mediaType: 'tv', season: 1, episode: 2, watchedAt: '2026-10-23T12:00:00Z' }],
    watchlist: [{ tmdbId: 550, mediaType: 'movie', listedAt: '2026-10-23T12:00:00Z' }]
  });
  assert.equal(simklPayloads.history?.shows.length, 1);
  assert.deepEqual(simklPayloads.watchlist?.movies, [{ to: 'plantowatch', ids: { tmdb: 550 } }]);
});

test('WeTrakr activities, compact rows, decimal ratings, favorites, dropped shows, and outbound payloads', () => {
  const act1 = parseWeTrakrActivities({
    movies: { last_tracking_watched_at: '2026-10-20T10:00:00Z', last_tracking_planning_at: '2026-10-20T11:00:00Z' },
    episodes: { last_tracking_watched_at: '2026-10-21T10:00:00Z' },
    shows: { last_tracking_dropped_at: '2026-10-22T10:00:00Z' },
    ratings: { all: '2026-10-23T10:00:00Z' },
    favorites: { all: '2026-10-23T11:00:00Z' }
  });
  assert.equal(changedWeTrakrDomains(act1, null).anyChanged, true);
  assert.equal(changedWeTrakrDomains(act1, act1).anyChanged, false);

  const act2 = parseWeTrakrActivities({
    movies: { last_tracking_watched_at: '2026-10-20T10:00:00Z', last_tracking_planning_at: '2026-10-20T11:00:00Z' },
    episodes: { last_tracking_watched_at: '2026-10-24T10:00:00Z' },
    shows: { last_tracking_dropped_at: '2026-10-22T10:00:00Z' },
    ratings: { all: '2026-10-23T10:00:00Z' },
    favorites: { all: '2026-10-23T11:00:00Z' }
  });
  const diff = changedWeTrakrDomains(act2, act1);
  assert.equal(diff.watchedMovies, false);
  assert.equal(diff.watchedEpisodes, true);
  assert.equal(diff.ratings, false);

  const snapshot = normalizeWeTrakrCompactRows({
    watchedMovies: [{ type: 'movie', ids: { tmdb: 550 }, last_watched_at: '2026-10-20T10:00:00Z', plays: 2 }],
    watchedEpisodes: [
      {
        type: 'episode',
        show_ids: { tmdb: 1399 },
        season_number: 1,
        number: 3,
        watched_at: '2026-10-21T10:00:00Z'
      }
    ],
    planningMovies: [{ type: 'movie', ids: { tmdb: 27205 }, status: 'planning', tracked_at: '2026-10-22T10:00:00Z' }],
    ratingsShows: [
      { type: 'show', ids: { tmdb: 1399 }, rating: 8.5, rated_at: '2026-10-23T10:00:00Z' },
      { type: 'show', ids: { tmdb: 66732 }, status: 'removed', removed_at: '2026-10-23T12:00:00Z' }
    ],
    favoritesMovies: [{ type: 'movie', ids: { tmdb: 550 }, favorited_at: '2026-10-23T11:00:00Z' }],
    droppedShows: [{ type: 'show', ids: { tmdb: 1402 }, status: 'dropped', tracked_at: '2026-10-22T10:00:00Z' }]
  });

  assert.equal(snapshot.provider, 'wetrakr');
  assert.equal(snapshot.plays.length, 2);
  assert.deepEqual(snapshot.plays[1], {
    tmdbId: 1399,
    mediaType: 'tv',
    season: 1,
    episode: 3,
    watchedAt: '2026-10-21T10:00:00Z'
  });
  assert.equal(snapshot.ratings.length, 2);
  assert.equal(snapshot.ratings[0]!.rating, 8.5);
  assert.equal(snapshot.ratings[1]!.removed, true);
  assert.equal(snapshot.favorites?.length, 1);
  assert.equal(snapshot.dropped?.length, 1);

  const wetrakrOut = buildOutboundProviderPayloads('wetrakr', {
    plays: [
      { tmdbId: 550, mediaType: 'movie', watchedAt: '2026-10-20T10:00:00Z' },
      { tmdbId: 1399, mediaType: 'tv', season: 1, episode: 3, watchedAt: '2026-10-21T10:00:00Z' }
    ],
    ratings: [{ tmdbId: 1399, mediaType: 'tv', rating: 8.5, ratedAt: '2026-10-23T10:00:00Z' }],
    watchlist: [{ tmdbId: 27205, mediaType: 'movie', listedAt: '2026-10-22T10:00:00Z' }],
    favorites: [{ tmdbId: 550, mediaType: 'movie', favoritedAt: '2026-10-23T11:00:00Z' }],
    dropped: [{ tmdbId: 1402, mediaType: 'tv', droppedAt: '2026-10-22T10:00:00Z' }]
  });
  assert.equal(wetrakrOut.history?.allow_rewatch, true);
  assert.deepEqual(wetrakrOut.history?.movies, [
    { status: 'watched', tracked_at: '2026-10-20T10:00:00Z', ids: { tmdb: 550 } }
  ]);
  assert.deepEqual(wetrakrOut.watchlist?.movies, [
    { status: 'planning', ids: { tmdb: 27205 } }
  ]);
  assert.deepEqual(wetrakrOut.watchlist?.shows, [
    { status: 'dropped', ids: { tmdb: 1402 } }
  ]);
  assert.deepEqual(wetrakrOut.favorites?.movies, [{ ids: { tmdb: 550 } }]);
});

test('ProviderConnectionSettings persists API credentials, status badges, and watch logging methods', () => {
  const memory = new Map<string, string>();
  const storage = {
    getItem: (key: string) => memory.get(key) ?? null,
    setItem: (key: string, value: string) => {
      memory.set(key, value);
    }
  };

  const initial = readProviderConnectionSettings(storage);
  assert.deepEqual(initial, defaultProviderConnectionSettings());
  assert.equal(providerStatusBadge(initial.wetrakr), 'Set up');
  assert.deepEqual(activeDirectLoggingProviders(initial), []);

  const updated = writeProviderConnectionSettings(
    {
      customTmdbToken: '  custom-tmdb-read-token  ',
      trakt: {
        provider: 'trakt',
        enabled: true,
        loggingMethod: 'server_only',
        clientId: 'trakt-cid',
        accessToken: 'trakt-pat'
      },
      wetrakr: {
        provider: 'wetrakr',
        enabled: true,
        loggingMethod: 'server_and_direct',
        clientId: 'wtk_app_123',
        accessToken: 'wtk_pat_456',
        username: 'cinephile'
      },
      simkl: {
        provider: 'simkl',
        enabled: false,
        loggingMethod: 'server_and_direct',
        clientId: 'simkl-cid'
      },
      mdblist: {
        provider: 'mdblist',
        enabled: true,
        loggingMethod: 'direct_only',
        apiKey: 'mdb_key_789'
      }
    },
    storage
  );

  assert.equal(updated.customTmdbToken, 'custom-tmdb-read-token');
  assert.equal(hasProviderCredentials(updated.simkl), true);
  assert.equal(isProviderAuthenticated(updated.simkl), false);
  assert.equal(providerStatusBadge(updated.simkl), 'Configured');
  assert.equal(providerStatusBadge(updated.wetrakr), 'Connected');
  assert.equal(providerStatusBadge(updated.mdblist), 'Connected');

  // Trakt uses server_only so only wetrakr (server_and_direct) and mdblist (direct_only) fan out directly
  assert.deepEqual(activeDirectLoggingProviders(updated), ['wetrakr', 'mdblist']);

  const reloaded = readProviderConnectionSettings(storage);
  assert.deepEqual(reloaded, updated);
});

test('bindings() overlays X-TMDB-Read-Token and X-MDBList-API-Key only for authenticated owner requests', async () => {
  const { bindings } = await import('../../src/lib/server/api.ts');
  const baseEnv = { TMDB_ACCESS_TOKEN: 'server-default-tmdb', MDBLIST_API_KEY: 'server-mdb' };

  // Unauthenticated request never overrides server bindings
  const unauth = bindings({
    locals: { bindings: baseEnv },
    request: new Request('https://diary.example/api/search', {
      headers: {
        'X-TMDB-Read-Token': 'custom-user-tmdb-token',
        'X-MDBList-API-Key': 'custom-user-mdb-key'
      }
    })
  });
  assert.equal(unauth.TMDB_ACCESS_TOKEN, 'server-default-tmdb');
  assert.equal(unauth.MDBLIST_API_KEY, 'server-mdb');

  // Authenticated owner request overrides TMDB_ACCESS_TOKEN and MDBLIST_API_KEY
  const authed = bindings({
    locals: {
      owner: { subject: 'owner-1', email: 'owner@example.com' },
      bindings: baseEnv
    },
    request: new Request('https://diary.example/api/search', {
      headers: {
        'X-TMDB-Read-Token': 'custom-user-tmdb-token',
        'X-MDBList-API-Key': 'custom-user-mdb-key'
      }
    })
  });
  assert.equal(authed.TMDB_ACCESS_TOKEN, 'custom-user-tmdb-token');
  assert.equal(authed.MDBLIST_API_KEY, 'custom-user-mdb-key');
});

test('Web provider outbox queues mutations, flushes outbound payloads, and handles PIN/Device Code OAuth', async () => {
  const {
    recordWebProviderMutation,
    flushWebProviderOutbox,
    pendingOutboxForProvider,
    startProviderDeviceAuth,
    pollProviderDeviceToken
  } = await import('../../src/lib/client/provider-outbox.ts');

  const store = new Map<string, string>();
  const storage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => {
      store.set(key, value);
    }
  };

  const settings = writeProviderConnectionSettings(
    {
      trakt: { provider: 'trakt', enabled: false, loggingMethod: 'server_only' },
      wetrakr: {
        provider: 'wetrakr',
        enabled: true,
        loggingMethod: 'server_and_direct',
        clientId: 'wtk_123',
        accessToken: 'wtk_pat_abc'
      },
      simkl: {
        provider: 'simkl',
        enabled: true,
        loggingMethod: 'direct_only',
        clientId: 'simkl_cid',
        accessToken: 'simkl_tok'
      },
      mdblist: { provider: 'mdblist', enabled: false, loggingMethod: 'server_and_direct' }
    },
    storage
  );

  recordWebProviderMutation(
    { kind: 'watch', titleId: 'm1', episodeId: null, watchedAt: '2026-10-23T18:00:00Z' },
    'op-watch-1',
    { settings, storage }
  );
  recordWebProviderMutation(
    { kind: 'patch', titleId: 'm1', score: 9.5, favorite: true },
    'op-patch-1',
    { settings, storage }
  );

  assert.equal(pendingOutboxForProvider('wetrakr', storage).length, 2);
  assert.equal(pendingOutboxForProvider('simkl', storage).length, 2);

  const requests: { url: string; headers: Record<string, string>; body: unknown }[] = [];
  const fakeTransport: typeof fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : input.toString();
    requests.push({
      url,
      headers: (init?.headers ?? {}) as Record<string, string>,
      body: init?.body ? JSON.parse(String(init.body)) : null
    });
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };

  const snapshot = {
    schemaVersion: 1 as const,
    titles: [
      {
        id: 'm1',
        name: 'After Rain',
        category: 'movie' as const,
        year: 2024,
        overview: '',
        poster: null,
        tmdbId: 550,
        genres: [],
        runtimeMinutes: 120,
        status: 'completed' as const,
        favorite: true,
        score: 9.5,
        notes: '',
        tags: []
      }
    ],
    episodes: [],
    events: [],
    locations: [],
    skippedEpisodeIds: []
  };

  const flushRes = await flushWebProviderOutbox(snapshot, {
    settings,
    storage,
    transport: fakeTransport
  });
  assert.equal(flushRes.flushedEntries, 4);
  assert.equal(pendingOutboxForProvider('wetrakr', storage).length, 0);
  assert.equal(pendingOutboxForProvider('simkl', storage).length, 0);
  assert.equal(requests.some((r) => r.url === 'https://api.wetrakr.com/sync/history'), true);
  assert.equal(requests.some((r) => r.url === 'https://api.wetrakr.com/sync/ratings'), true);
  assert.equal(requests.some((r) => r.url === 'https://api.wetrakr.com/sync/favorites'), true);
  assert.equal(requests.some((r) => r.url === 'https://api.simkl.com/sync/history'), true);
  assert.equal(requests.some((r) => r.url === 'https://api.simkl.com/sync/ratings'), true);

  // Test Simkl PIN & Trakt Device Code OAuth helpers
  const authTransport: typeof fetch = async (input) => {
    const url = typeof input === 'string' ? input : input.toString();
    if (url.startsWith('https://api.simkl.com/oauth/pin?')) {
      return new Response(
        JSON.stringify({ user_code: 'SIMKL99', verification_url: 'https://simkl.com/pin' }),
        { status: 200 }
      );
    }
    if (url.startsWith('https://api.simkl.com/oauth/pin/SIMKL99')) {
      return new Response(
        JSON.stringify({ result: 'OK', access_token: 'simkl_new_oauth_token' }),
        { status: 200 }
      );
    }
    return new Response('{}', { status: 400 });
  };
  const pinSession = await startProviderDeviceAuth('simkl', 'simkl_cid', authTransport);
  assert.equal(pinSession.userCode, 'SIMKL99');
  const polled = await pollProviderDeviceToken(pinSession, 'simkl_cid', '', authTransport);
  assert.deepEqual(polled, { status: 'authorized', accessToken: 'simkl_new_oauth_token' });
});

test('applyNormalizedProviderSnapshotToDiary merges WeTrakr & Simkl plays, ratings, favorites, and dropped status into D1', async () => {
  const { d1Fixture } = await import('../helpers/d1.ts');
  const { addManualTitle, getTitle } = await import('../../src/lib/server/library.ts');
  const { providerIdentities } = await import('../../src/lib/server/db/schema.ts');
  const { applyNormalizedProviderSnapshotToDiary } = await import('../../src/lib/server/providers.ts');

  const f = d1Fixture();
  try {
    await addManualTitle(f.db, {
      id: 'movie-550',
      name: 'Fight Club',
      category: 'movie',
      year: 1999,
      status: 'planned'
    });
    await f.db
      .insert(providerIdentities)
      .values({
        id: 'tmdb-movie-550',
        titleId: 'movie-550',
        provider: 'tmdb',
        kind: 'movie',
        externalId: '550'
      })
      .run();

    const result = await applyNormalizedProviderSnapshotToDiary(f.db, {
      provider: 'wetrakr',
      plays: [{ tmdbId: 550, mediaType: 'movie', watchedAt: '2026-10-20T20:00:00.000Z' }],
      ratings: [{ tmdbId: 550, mediaType: 'movie', rating: 9.5, ratedAt: '2026-10-20T21:00:00.000Z' }],
      watchlist: [],
      favorites: [{ tmdbId: 550, mediaType: 'movie', favoritedAt: '2026-10-20T21:05:00.000Z' }]
    });

    assert.equal(result.importedPlays, 1);
    assert.equal(result.updatedRatings, 1);
    assert.equal(result.updatedFavorites, 1);

    const updated = await getTitle(f.db, 'movie-550');
    assert.equal(updated.status, 'completed');
    assert.equal(updated.score, 9.5);
    assert.equal(updated.favorite, true);

    // Re-running is idempotent
    const second = await applyNormalizedProviderSnapshotToDiary(f.db, {
      provider: 'wetrakr',
      plays: [{ tmdbId: 550, mediaType: 'movie', watchedAt: '2026-10-20T20:00:00.000Z' }],
      ratings: [{ tmdbId: 550, mediaType: 'movie', rating: 9.5, ratedAt: '2026-10-20T21:00:00.000Z' }],
      watchlist: [],
      favorites: [{ tmdbId: 550, mediaType: 'movie', favoritedAt: '2026-10-20T21:05:00.000Z' }]
    });
    assert.equal(second.importedPlays, 0);
    assert.equal(second.updatedRatings, 0);
    assert.equal(second.updatedFavorites, 0);
  } finally {
    f.close();
  }
});

test('importDiaryArchive performs repeatable 3-way merge of DiaryExport JSON backups into D1', async () => {
  const { d1Fixture } = await import('../helpers/d1.ts');
  const { importDiaryArchive } = await import('../../src/lib/server/workspace-migration.ts');
  const { getTitle } = await import('../../src/lib/server/library.ts');
  const { workspacePage } = await import('../../src/lib/server/workspace.ts');

  const f = d1Fixture();
  try {
    const archive1 = {
      schemaVersion: 1,
      titles: [
        {
          id: 'backup-series-1',
          name: 'Frieren',
          category: 'anime',
          year: 2023,
          overview: 'Beyond Journey’s End',
          poster: null,
          tmdbId: 209867,
          version: 1,
          genres: ['Fantasy'],
          runtimeMinutes: 24,
          status: 'watching',
          favorite: false,
          score: null,
          notes: 'Initial note',
          tags: ['magic']
        }
      ],
      episodes: [
        {
          id: 'ep-frieren-s1e1',
          titleId: 'backup-series-1',
          season: 1,
          number: 1,
          name: 'The Journey’s End',
          overview: 'Episode 1',
          airedOn: '2023-09-29'
        }
      ],
      events: [
        {
          id: 'ev-frieren-1',
          operationId: 'op-frieren-1',
          titleId: 'backup-series-1',
          episodeId: 'ep-frieren-s1e1',
          watchedAt: '2026-10-20T18:00:00.000Z',
          recordedAt: '2026-10-20T18:00:00.000Z',
          revokedAt: null,
          origin: 'manual'
        }
      ],
      locations: [],
      skippedEpisodeIds: []
    };

    const res1 = await importDiaryArchive(f.db, archive1);
    assert.equal(res1.importedTitles, 1);
    assert.equal(res1.importedEpisodes, 1);
    assert.equal(res1.importedEvents, 1);

    const t1 = await getTitle(f.db, 'backup-series-1');
    assert.equal(t1.name, 'Frieren');
    assert.equal(t1.notes, 'Initial note');
    assert.equal(t1.score, null);

    // Import an updated archive with higher version, score=9.5, favorite=true
    const archive2 = {
      ...archive1,
      titles: [
        {
          ...archive1.titles[0],
          version: 2,
          status: 'completed',
          favorite: true,
          score: 9.5
        }
      ]
    };
    const res2 = await importDiaryArchive(f.db, archive2);
    assert.equal(res2.importedTitles, 1);

    const t2 = await getTitle(f.db, 'backup-series-1');
    assert.equal(t2.status, 'completed');
    assert.equal(t2.favorite, true);
    assert.equal(t2.score, 9.5);
    assert.equal(t2.notes, 'Initial note');

    const eventsPage = await workspacePage(f.db, new URLSearchParams({ section: 'events' }));
    assert.equal(eventsPage.items.length, 1);
  } finally {
    f.close();
  }
});

test('Stage 4: MDBList community ratings, series metadata refresh, and offline diary mutation replay', async () => {
  const { createMDBListRatings } = await import('../../src/lib/server/community-ratings.ts');
  const { ratingSource, ratingSourceLabel } = await import('../../src/lib/domain/community-ratings.ts');
  const { refreshTitleMetadata } = await import('../../src/lib/server/metadata-import.ts');
  const { enqueueOfflineDiaryMutation, flushOfflineDiaryMutations, readOfflineDiaryQueue } =
    await import('../../src/lib/client/provider-outbox.ts');
  const { d1Fixture } = await import('../helpers/d1.ts');
  const { addManualTitle, patchTitle } = await import('../../src/lib/server/library.ts');
  const { providerIdentities, seasons } = await import('../../src/lib/server/db/schema.ts');
  const { eq } = await import('drizzle-orm');

  // 1. MDBList Community Ratings
  assert.equal(ratingSource('mdblist'), 'mdblist');
  assert.equal(ratingSourceLabel.mdblist, 'MDBList');

  let mdbCalls = 0;
  const mdbRatings = createMDBListRatings(async (url) => {
    mdbCalls++;
    assert.equal(String(url), 'https://api.mdblist.com/tmdb/show/209867?apikey=mdb_test_key');
    return Response.json({
      score: 88,
      ratings: [
        { source: 'imdb', value: 8.9, score: 89 },
        { source: 'trakt', value: 87, score: 87 }
      ]
    });
  });
  const idents = [{ provider: 'tmdb', externalId: '209867', kind: 'series' as const }];
  const [r1, r2] = await Promise.all([
    mdbRatings(idents, 'mdb_test_key'),
    mdbRatings(idents, 'mdb_test_key')
  ]);
  assert.deepEqual(r1, { score: 8.8, state: 'rated' });
  assert.deepEqual(r1, r2);
  assert.equal(mdbCalls, 1);

  // 2. Ongoing Series Top-Level Metadata & New Season Discovery Refresh
  const f = d1Fixture();
  try {
    await addManualTitle(f.db, {
      id: 'series-frieren',
      name: 'Frieren',
      category: 'anime',
      year: 2023,
      status: 'watching'
    });
    await patchTitle(f.db, 'series-frieren', {
      expectedVersion: 1,
      score: 9.8,
      favorite: true,
      notes: 'Keep my personal note'
    });
    await f.db
      .insert(providerIdentities)
      .values({
        id: 'tmdb-series-209867',
        titleId: 'series-frieren',
        provider: 'tmdb',
        kind: 'series',
        externalId: '209867'
      })
      .run();
    await f.db
      .insert(seasons)
      .values({
        id: 'series-frieren-s1',
        titleId: 'series-frieren',
        number: 1,
        name: 'Season 1',
        expectedEpisodes: 28
      })
      .run();

    const fakeTmdbClient = {
      details: async (mediaType: 'movie' | 'tv', id: number) => {
        assert.equal(mediaType, 'tv');
        assert.equal(id, 209867);
        return {
          id: 209867,
          mediaType: 'tv' as const,
          name: 'Frieren: Beyond Journey’s End',
          year: 2023,
          overview: 'Updated TMDb overview',
          posterPath: '/frieren-poster.jpg',
          backdropPath: '/frieren-backdrop.jpg',
          runtimeMinutes: 24,
          genres: ['Animation', 'Fantasy'],
          communityScore: 8.9,
          imdbId: 'tt22248376',
          seasons: [
            { number: 1, name: 'Season 1', expectedEpisodes: 28 },
            { number: 2, name: 'Season 2', expectedEpisodes: 24 }
          ]
        };
      }
    };

    const refreshed = await refreshTitleMetadata(
      f.db,
      fakeTmdbClient as never,
      'series-frieren'
    );
    assert.equal(refreshed.addedSeasons, 1);
    assert.equal(refreshed.title.overview, 'Updated TMDb overview');
    assert.equal(refreshed.title.communityScore, 8.9);
    // Personal fields preserved
    assert.equal(refreshed.title.score, 9.8);
    assert.equal(refreshed.title.favorite, true);
    assert.equal(refreshed.title.notes, 'Keep my personal note');

    const allSeasons = await f.db
      .select()
      .from(seasons)
      .where(eq(seasons.titleId, 'series-frieren'))
      .all();
    assert.equal(allSeasons.length, 2);
  } finally {
    f.close();
  }

  // 3. Offline Primary Diary Mutation Queue & Replay
  const mem = new Map<string, string>();
  const storage = {
    getItem: (k: string) => mem.get(k) ?? null,
    setItem: (k: string, v: string) => {
      mem.set(k, v);
    }
  };
  enqueueOfflineDiaryMutation(
    {
      operationId: 'offline-op-1',
      path: '/api/titles/series-frieren/watches',
      method: 'POST',
      body: {
        operationId: 'offline-op-1',
        episodeId: 'ep-1',
        watchedAt: '2026-10-23T19:00:00Z',
        rewatch: false
      }
    },
    storage
  );
  // Deduplicates same operationId
  enqueueOfflineDiaryMutation(
    {
      operationId: 'offline-op-1',
      path: '/api/titles/series-frieren/watches',
      method: 'POST',
      body: {
        operationId: 'offline-op-1',
        episodeId: 'ep-1',
        watchedAt: '2026-10-23T19:00:00Z',
        rewatch: false
      }
    },
    storage
  );
  assert.equal(readOfflineDiaryQueue(storage).length, 1);

  let online = false;
  const offlineRes = await flushOfflineDiaryMutations({
    storage,
    transport: async () => {
      if (!online) throw new TypeError('Failed to fetch');
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }
  });
  assert.deepEqual(offlineRes, { replayed: 0, remaining: 1 });

  online = true;
  const onlineRes = await flushOfflineDiaryMutations({
    storage,
    transport: async () => new Response(JSON.stringify({ ok: true }), { status: 200 })
  });
  assert.deepEqual(onlineRes, { replayed: 1, remaining: 0 });
  assert.equal(readOfflineDiaryQueue(storage).length, 0);
});

test('importDiaryArchive marks unchanged titles with historic child events as updated for delta sync', async () => {
  const { d1Fixture } = await import('../helpers/d1.ts');
  const { importDiaryArchive } = await import('../../src/lib/server/workspace-migration.ts');
  const { workspaceChanges } = await import('../../src/lib/server/workspace.ts');
  const { readWorkspaceRevision, bumpWorkspaceRevision } = await import(
    '../../src/lib/server/workspace-revision.ts'
  );

  const f = d1Fixture();
  try {
    await importDiaryArchive(f.db, {
      schemaVersion: 1,
      titles: [
        {
          id: 'movie-a',
          name: 'Movie A',
          category: 'movie',
          year: 2022,
          overview: '',
          poster: null,
          version: 1,
          genres: [],
          runtimeMinutes: 100,
          status: 'planned',
          favorite: false,
          score: null,
          notes: '',
          tags: []
        },
        {
          id: 'movie-b',
          name: 'Movie B',
          category: 'movie',
          year: 2021,
          overview: '',
          poster: null,
          version: 1,
          genres: [],
          runtimeMinutes: 110,
          status: 'completed',
          favorite: false,
          score: 8.0,
          notes: '',
          tags: []
        }
      ],
      episodes: [],
      events: [],
      locations: [],
      skippedEpisodeIds: []
    });
    await bumpWorkspaceRevision(f.binding);
    const revBefore = await readWorkspaceRevision(f.db);
    await new Promise((r) => setTimeout(r, 15));
    const sinceBeforeImport = new Date().toISOString();
    await new Promise((r) => setTimeout(r, 15));

    // Import an archive that bumps movie-a to v2 and adds a historic 2024 watch event to movie-b (still v1)
    await importDiaryArchive(f.db, {
      schemaVersion: 1,
      titles: [
        {
          id: 'movie-a',
          name: 'Movie A',
          category: 'movie',
          year: 2022,
          overview: '',
          poster: null,
          version: 2,
          genres: [],
          runtimeMinutes: 100,
          status: 'watching',
          favorite: false,
          score: null,
          notes: '',
          tags: []
        },
        {
          id: 'movie-b',
          name: 'Movie B',
          category: 'movie',
          year: 2021,
          overview: '',
          poster: null,
          version: 1,
          genres: [],
          runtimeMinutes: 110,
          status: 'completed',
          favorite: false,
          score: 8.0,
          notes: '',
          tags: []
        }
      ],
      episodes: [],
      events: [
        {
          id: 'historic-ev-b',
          operationId: 'historic-op-b',
          titleId: 'movie-b',
          episodeId: null,
          watchedAt: '2024-01-15T20:00:00.000Z',
          recordedAt: '2024-01-15T20:00:00.000Z',
          revokedAt: null,
          origin: 'import'
        }
      ],
      locations: [],
      skippedEpisodeIds: []
    });
    await bumpWorkspaceRevision(f.binding);

    const delta = await workspaceChanges(
      f.db,
      new URLSearchParams({ since: sinceBeforeImport, known: revBefore.revision }),
      readWorkspaceRevision
    );
    assert.equal(delta.fullRefreshRequired, false);
    assert.deepEqual(delta.titles.map((t) => t.id).sort(), ['movie-a', 'movie-b']);
    assert.equal(delta.events.some((e) => e.id === 'historic-ev-b'), true);
  } finally {
    f.close();
  }
});

test('Stage 5: Multi-method authentication, Anime + Show Airing Calendar, MDBList critic breakdown, and CSV import', async () => {
  const {
    AccessFailure,
    availableAuthMethods,
    signDiarySessionToken,
    timingSafeEqualString,
    verifyDiarySessionToken,
    verifyMultiMethodRequest
  } = await import('../../src/lib/server/access.ts');
  const { upcomingSchedule } = await import('../../src/lib/domain/home.ts');
  const { sampleDiary } = await import('../../src/lib/preview/fixtures.ts');
  const { createMDBListBreakdown } = await import('../../src/lib/server/community-ratings.ts');
  const { importDiaryArchive, parseExternalCsvToArchive } = await import(
    '../../src/lib/server/workspace-migration.ts'
  );
  const { d1Fixture } = await import('../helpers/d1.ts');

  // 1. Multi-Method Authentication (Personal Access Token + Signed Session JWT for Passcode / Provider OAuth)
  assert.equal(timingSafeEqualString('secret-token-1234', 'secret-token-1234'), true);
  assert.equal(timingSafeEqualString('secret-token-1234', 'secret-token-9999'), false);
  assert.equal(timingSafeEqualString('short', 'longer-string'), false);

  const authEnv = {
    DIARY_ACCESS_TOKEN: 'twil_pat_9876543210abcdef',
    DIARY_OWNER_EMAIL: 'owner@twildiary.test',
    DIARY_OWNER_PASSCODE: 'correct-horse-battery',
    DIARY_AUTH_SECRET: 'super-secret-signing-key-2026'
  };
  const methods = availableAuthMethods(authEnv);
  assert.equal(methods.personalToken, true);
  assert.equal(methods.passcode, true);
  assert.equal(methods.cloudflareAccess, false);

  // Verify Personal Access Token via Authorization: Bearer, X-Diary-Access-Token, and CF_Authorization cookie
  const patOwner1 = await verifyMultiMethodRequest(
    new Request('https://diary.example.test/api/workspace', {
      headers: { Authorization: 'Bearer twil_pat_9876543210abcdef' }
    }),
    authEnv
  );
  assert.equal(patOwner1.email, 'owner@twildiary.test');
  assert.equal(patOwner1.method, 'personal_token');

  const patOwner2 = await verifyMultiMethodRequest(
    new Request('https://diary.example.test/api/workspace', {
      headers: { Cookie: 'CF_Authorization=twil_pat_9876543210abcdef' }
    }),
    authEnv
  );
  assert.equal(patOwner2.method, 'personal_token');

  // Issue and verify signed session JWT (for Passcode and Provider OAuth sign-in)
  const signedSession = await signDiarySessionToken(
    { subject: 'passcode:owner@twildiary.test', email: 'owner@twildiary.test', method: 'passcode' },
    authEnv
  );
  const verifiedDirect = await verifyDiarySessionToken(signedSession.token, authEnv);
  assert.equal(verifiedDirect?.email, 'owner@twildiary.test');
  assert.equal(verifiedDirect?.method, 'passcode');

  const sessionCookieOwner = await verifyMultiMethodRequest(
    new Request('https://diary.example.test/api/workspace', {
      headers: { Cookie: `twildiary_session=${signedSession.token}` }
    }),
    authEnv
  );
  assert.equal(sessionCookieOwner.email, 'owner@twildiary.test');
  assert.equal(sessionCookieOwner.method, 'passcode');

  // Wrong token must fail with 401 AccessFailure
  await assert.rejects(
    () =>
      verifyMultiMethodRequest(
        new Request('https://diary.example.test/api/workspace', {
          headers: { Authorization: 'Bearer wrong_token_value' }
        }),
        authEnv
      ),
    (e: unknown) => e instanceof AccessFailure && e.status === 401
  );

  // 2. Upcoming Airing Calendar & Schedule (Anime + TV Shows)
  const diary = sampleDiary();
  const baseTitle = diary.titles[0]!;
  diary.titles = [
    { ...baseTitle, id: 'frieren-anime', name: 'Frieren', category: 'anime', status: 'watching' },
    { ...baseTitle, id: 'andor-show', name: 'Andor', category: 'show', status: 'watching' }
  ];
  diary.events = [];
  diary.skippedEpisodeIds = [];
  diary.episodes = [
    {
      id: 'fr-1',
      titleId: 'frieren-anime',
      season: 2,
      number: 1,
      name: 'Journey Continues',
      overview: '',
      airedOn: '2026-10-23'
    },
    {
      id: 'fr-2',
      titleId: 'frieren-anime',
      season: 2,
      number: 2,
      name: 'Northern Plateau',
      overview: '',
      airedOn: '2026-10-30'
    },
    {
      id: 'an-1',
      titleId: 'andor-show',
      season: 2,
      number: 1,
      name: 'One Year Later',
      overview: '',
      airedOn: '2026-10-24'
    }
  ];
  const now = new Date('2026-10-23T05:00:00Z');
  const fullCal = upcomingSchedule(diary, {
    now,
    timeZone: 'Asia/Kolkata',
    category: 'all',
    horizonDays: 30,
    dedupeByTitle: false
  });
  assert.equal(fullCal.counts.total, 3);
  assert.equal(fullCal.counts.anime, 2);
  assert.equal(fullCal.counts.show, 1);
  assert.equal(fullCal.counts.today, 1);
  assert.equal(fullCal.strip.length, 14);
  assert.equal(fullCal.strip[0]!.animeCount, 1);
  assert.equal(fullCal.strip[1]!.showCount, 1);

  const animeOnly = upcomingSchedule(diary, {
    now,
    timeZone: 'Asia/Kolkata',
    category: 'anime',
    horizonDays: 30
  });
  assert.equal(animeOnly.items.length, 2);
  assert.equal(
    animeOnly.items.every((i) => i.category === 'anime'),
    true
  );

  const dedupedCal = upcomingSchedule(diary, {
    now,
    timeZone: 'Asia/Kolkata',
    category: 'all',
    horizonDays: 30,
    dedupeByTitle: true
  });
  assert.equal(dedupedCal.items.length, 2);

  // 3. MDBList Multi-Critic Breakdown
  const breakdownFetcher = createMDBListBreakdown(async () =>
    Response.json({
      score: 91,
      ratings: [
        { source: 'imdb', value: 9.0, score: 90 },
        { source: 'tomatoes', value: 96, score: 96 },
        { source: 'metacritic', value: 87, score: 87 },
        { source: 'letterboxd', value: 4.5, score: 90 }
      ]
    })
  );
  const breakdown = await breakdownFetcher(
    [{ provider: 'tmdb', externalId: '209867', kind: 'series' }],
    'mdb_key'
  );
  assert.equal(breakdown.score, 9.1);
  assert.equal(breakdown.sources.length, 4);
  assert.deepEqual(
    breakdown.sources.map((s) => s.label),
    ['IMDb', 'Rotten Tomatoes', 'Metacritic', 'Letterboxd']
  );

  // 4. Universal Third-Party CSV Import (Letterboxd / IMDb / MAL)
  const letterboxdCsv = [
    'Date,Name,Year,Letterboxd URI,Rating,Watched Date',
    '2026-10-01,"Spirited Away",2001,https://boxd.it/1,4.5,2026-10-01',
    '2026-10-02,"Seven Samurai",1954,https://boxd.it/2,5.0,2026-10-02'
  ].join('\n');
  const csvArchive = parseExternalCsvToArchive(letterboxdCsv);
  assert.equal(csvArchive.titles.length, 2);
  assert.equal(csvArchive.titles[0]!.personalRating, 9);
  assert.equal(csvArchive.titles[1]!.personalRating, 10);
  assert.equal(csvArchive.events.length, 2);

  const f = d1Fixture();
  try {
    const res = await importDiaryArchive(f.db, csvArchive);
    assert.equal(res.importedTitles, 2);
    assert.equal(res.importedEvents, 2);
  } finally {
    f.close();
  }
});

test('Stage 6: Catch-up airing schedule, .ics export, encrypted cross-device provider vault, and custom collection tags', async () => {
  const { formatAiringCalendarICS, upcomingSchedule } = await import('../../src/lib/domain/home.ts');
  const { sampleDiary } = await import('../../src/lib/preview/fixtures.ts');
  const { readProviderVault, writeProviderVault } = await import(
    '../../src/lib/server/provider-vault.ts'
  );
  const { addManualTitle, patchTitle } = await import('../../src/lib/server/library.ts');
  const { workspaceTitles } = await import('../../src/lib/server/workspace.ts');
  const { d1Fixture } = await import('../helpers/d1.ts');

  // 1. Catch-Up (Recently Aired) Mode & .ics iCalendar Export
  const diary = sampleDiary();
  const baseTitle = diary.titles[0]!;
  diary.titles = [
    { ...baseTitle, id: 'dandadan', name: 'Dan Da Dan', category: 'anime', status: 'watching' }
  ];
  diary.events = [];
  diary.skippedEpisodeIds = [];
  diary.episodes = [
    {
      id: 'ddd-past',
      titleId: 'dandadan',
      season: 1,
      number: 4,
      name: 'Turbo Granny',
      overview: '',
      airedOn: '2026-10-20'
    },
    {
      id: 'ddd-future',
      titleId: 'dandadan',
      season: 1,
      number: 5,
      name: 'Acrobatic Silky',
      overview: '',
      airedOn: '2026-10-27'
    }
  ];
  const now = new Date('2026-10-23T05:00:00Z');
  const catchup = upcomingSchedule(diary, {
    now,
    timeZone: 'Asia/Kolkata',
    mode: 'catchup',
    horizonDays: 7
  });
  assert.equal(catchup.items.length, 1);
  assert.equal(catchup.items[0]!.episode.id, 'ddd-past');
  assert.equal(catchup.items[0]!.daysAway, -3);

  const upcoming = upcomingSchedule(diary, {
    now,
    timeZone: 'Asia/Kolkata',
    mode: 'upcoming',
    horizonDays: 7
  });
  const ics = formatAiringCalendarICS(upcoming, { hideSpoilers: false });
  assert.equal(ics.includes('BEGIN:VCALENDAR'), true);
  assert.equal(ics.includes('SUMMARY:Dan Da Dan · S01E05'), true);
  assert.equal(ics.includes('Acrobatic Silky'), true);

  // 2. Cross-Device Encrypted Provider Credential Vault + Custom Collection Tags in D1
  const f = d1Fixture();
  try {
    const vaultEnv = { DIARY_AUTH_SECRET: 'vault-encryption-secret-key-2026' };
    const initial = await readProviderVault(f.db, vaultEnv);
    assert.equal(initial.synced, false);

    const saved = await writeProviderVault(f.db, vaultEnv, {
      customTmdbToken: 'tmdb_read_tok_xyz',
      simkl: { enabled: true, clientId: 'simkl_cid', accessToken: 'simkl_tok' },
      mdblist: { enabled: true, apiKey: 'mdb_api_key_99' }
    });
    assert.equal(saved.synced, true);

    const restored = await readProviderVault(f.db, vaultEnv);
    assert.equal(restored.synced, true);
    assert.equal(restored.settings?.customTmdbToken, 'tmdb_read_tok_xyz');
    assert.equal(restored.settings?.simkl?.accessToken, 'simkl_tok');
    assert.equal(restored.settings?.mdblist?.apiKey, 'mdb_api_key_99');

    // Wrong key cannot decrypt vault
    const wrongKeyRead = await readProviderVault(f.db, {
      DIARY_AUTH_SECRET: 'different-secret-key-value'
    });
    assert.equal(wrongKeyRead.synced, false);
    assert.equal(wrongKeyRead.settings, null);

    // 3. Custom Collection Tags via patchTitle & workspaceTitles
    await addManualTitle(f.db, {
      id: 'tagged-anime',
      name: 'Frieren',
      category: 'anime',
      year: 2023,
      status: 'watching'
    });
    const patched = await patchTitle(f.db, 'tagged-anime', {
      expectedVersion: 1,
      tags: ['Fall Anime', 'Weekend']
    });
    assert.deepEqual((patched.title as { tags?: string[] }).tags, ['Fall Anime', 'Weekend']);

    const page = await workspaceTitles(f.db, new URLSearchParams({ ids: 'tagged-anime' }));
    const found = page.titles.find((t) => t.id === 'tagged-anime');
    assert.deepEqual(found?.tags, ['Fall Anime', 'Weekend']);
  } finally {
    f.close();
  }
});

test('Stage 7: Exhaustive route-level Auth (4 methods + security), Sync Integrations, Metadata Episode Refresh, Vault Tamper Resistance, and Torture Tests', async () => {
  const { GET: authGet, POST: authPost, DELETE: authDelete } = await import(
    '../../src/routes/api/auth/+server.ts'
  );
  const {
    AccessFailure,
    createAccessVerifier,
    signDiarySessionToken,
    verifyMultiMethodRequest
  } = await import('../../src/lib/server/access.ts');
  const { generateKeyPair, SignJWT } = await import('jose');
  const { traktConnections } = await import('../../src/lib/server/db/schema.ts');
  const { refreshTitleMetadata, importTmdb } = await import(
    '../../src/lib/server/metadata-import.ts'
  );
  const { importDiaryArchive, parseExternalCsvToArchive } = await import(
    '../../src/lib/server/workspace-migration.ts'
  );
  const { workspaceChanges } = await import('../../src/lib/server/workspace.ts');
  const { changesDiary, readWorkspaceRevision } = await import(
    '../../src/lib/server/workspace-revision.ts'
  );
  const { decryptVaultPayload, encryptVaultPayload, readProviderVault, writeProviderVault } =
    await import('../../src/lib/server/provider-vault.ts');
  const { filterLibrary } = await import('../../src/lib/domain/library.ts');
  const { formatAiringCalendarICS, upcomingSchedule } = await import('../../src/lib/domain/home.ts');
  const { sampleDiary } = await import('../../src/lib/preview/fixtures.ts');
  const { d1Fixture } = await import('../helpers/d1.ts');

  // 1. changesDiary excludes non-diary auth and vault writes
  assert.equal(changesDiary('POST', '/api/auth'), false);
  assert.equal(changesDiary('PUT', '/api/providers/vault'), false);
  assert.equal(changesDiary('POST', '/api/workspace/import'), true);
  assert.equal(changesDiary('POST', '/api/titles/frieren/metadata'), true);

  const f = d1Fixture();
  const originalFetch = globalThis.fetch;
  try {
    const env = {
      DB: f.binding,
      DIARY_ACCESS_TOKEN: 'pat_live_token_abc123456',
      DIARY_OWNER_EMAIL: 'owner@twildiary.test',
      DIARY_OWNER_PASSCODE: 'passcode_xyz_987',
      DIARY_AUTH_SECRET: 'signing_secret_key_for_tests_2026',
      TRAKT_CLIENT_ID: 'trakt_cid_test'
    };

    // 2. GET /api/auth reports all configured methods
    const getRes = await authGet({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth')
    } as never);
    assert.equal(getRes.status, 200);
    const getBody = (await getRes.json()) as {
      authenticated: boolean;
      methods: Record<string, boolean>;
    };
    assert.equal(getBody.authenticated, false);
    assert.equal(getBody.methods.personalToken, true);
    assert.equal(getBody.methods.passcode, true);
    assert.equal(getBody.methods.providerOAuth, true);

    // 3. POST /api/auth — Method 1: Personal Access Token (valid + invalid)
    const patRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ method: 'token', token: 'pat_live_token_abc123456' })
      })
    } as never);
    assert.equal(patRes.status, 200);
    assert.match(patRes.headers.get('set-cookie') ?? '', /twildiary_session=eyJ/);
    const patData = (await patRes.json()) as { authenticated: boolean; token: string; method: string };
    assert.equal(patData.authenticated, true);
    assert.equal(patData.method, 'personal_token');

    const badPatRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ method: 'token', token: 'wrong_pat_value' })
      })
    } as never);
    assert.equal(badPatRes.status, 401);

    // 4. POST /api/auth — Method 2: Owner Email & Passcode (case-insensitive email + wrong passcode)
    const passRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'passcode',
          email: 'OWNER@TWILDIARY.TEST',
          passcode: 'passcode_xyz_987'
        })
      })
    } as never);
    assert.equal(passRes.status, 200);
    const passData = (await passRes.json()) as { token: string; method: string; email: string };
    assert.equal(passData.method, 'passcode');
    assert.equal(passData.email, 'owner@twildiary.test');

    const badPassRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'passcode',
          email: 'owner@twildiary.test',
          passcode: 'wrong_passcode'
        })
      })
    } as never);
    assert.equal(badPassRes.status, 401);

    // 5. POST /api/auth — Method 3: Trakt OAuth (connected owner match vs wrong account)
    await f.db.insert(traktConnections).values({
      id: 'trakt',
      state: 'connected',
      accountId: 'trakt-uuid-owner-1',
      username: 'twil_owner',
      clientId: 'trakt_cid_test',
      ciphertext: 'enc',
      expiresAt: 2000000000,
      updatedAt: '2026-10-01T00:00:00Z'
    });

    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      if (url === 'https://api.trakt.tv/users/settings') {
        const auth = new Headers(init?.headers).get('Authorization');
        if (auth === 'Bearer valid_trakt_oauth_tok') {
          return Response.json({
            user: { username: 'twil_owner', ids: { uuid: 'trakt-uuid-owner-1', slug: 'twil_owner' } }
          });
        }
        if (auth === 'Bearer impostor_trakt_tok') {
          return Response.json({
            user: { username: 'impostor', ids: { uuid: 'trakt-uuid-other', slug: 'impostor' } }
          });
        }
        return new Response('Unauthorized', { status: 401 });
      }
      return new Response('Not found', { status: 404 });
    }) as typeof fetch;

    const traktAuthRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'provider',
          provider: 'trakt',
          accessToken: 'valid_trakt_oauth_tok'
        })
      })
    } as never);
    assert.equal(traktAuthRes.status, 200);
    const traktAuthData = (await traktAuthRes.json()) as { token: string; method: string };
    assert.equal(traktAuthData.method, 'provider_oauth');

    // Verify providerOAuth-only server accepts the issued session token
    const providerOnlyOwner = await verifyMultiMethodRequest(
      new Request('https://diary.example.test/api/workspace', {
        headers: { Authorization: `Bearer ${traktAuthData.token}` }
      }),
      { DB: f.binding, DIARY_AUTH_SECRET: env.DIARY_AUTH_SECRET }
    );
    assert.equal(providerOnlyOwner.method, 'provider_oauth');

    // Impostor Trakt user is rejected with 403 wrong_owner
    const impostorRes = await authPost({
      locals: { bindings: env },
      url: new URL('https://diary.example.test/api/auth'),
      request: new Request('https://diary.example.test/api/auth', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'provider',
          provider: 'trakt',
          accessToken: 'impostor_trakt_tok'
        })
      })
    } as never);
    assert.equal(impostorRes.status, 403);

    // 6. Method 4: Cloudflare Access RS256 JWT (via header and CF_Authorization cookie)
    const { publicKey, privateKey } = await generateKeyPair('RS256');
    const cfConfig = {
      issuer: 'https://twil-test.cloudflareaccess.com',
      audience: 'cf-aud-123',
      ownerEmail: 'owner@twildiary.test'
    };
    const cfVerifier = createAccessVerifier(cfConfig, async () => publicKey);
    const cfJwt = await new SignJWT({ type: 'app', email: cfConfig.ownerEmail })
      .setProtectedHeader({ alg: 'RS256' })
      .setSubject('cf-sub-1')
      .setIssuer(cfConfig.issuer)
      .setAudience(cfConfig.audience)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const cfEnv = {
      ACCESS_TEAM_DOMAIN: 'twil-test.cloudflareaccess.com',
      ACCESS_AUDIENCE: 'cf-aud-123',
      ACCESS_OWNER_EMAIL: 'owner@twildiary.test'
    };
    const cfCookieOwner = await verifyMultiMethodRequest(
      new Request('https://diary.example.test/api/workspace', {
        headers: { Cookie: `CF_Authorization=${cfJwt}` }
      }),
      cfEnv,
      cfVerifier
    );
    assert.equal(cfCookieOwner.method, 'cloudflare_access');
    assert.equal(cfCookieOwner.email, 'owner@twildiary.test');

    // Expired session token is rejected
    const expiredSession = await signDiarySessionToken(
      { subject: 'exp-sub', email: 'owner@twildiary.test', method: 'passcode' },
      env,
      -60
    );
    await assert.rejects(
      () =>
        verifyMultiMethodRequest(
          new Request('https://diary.example.test/api/workspace', {
            headers: { Authorization: `Bearer ${expiredSession.token}` }
          }),
          env
        ),
      (e: unknown) => e instanceof AccessFailure && e.status === 401
    );

    // DELETE /api/auth clears cookies
    const delRes = await authDelete({
      url: new URL('https://diary.example.test/api/auth')
    } as never);
    assert.equal(delRes.status, 200);
    assert.match(delRes.headers.get('set-cookie') ?? '', /Max-Age=0/);

    // 7. Vault Tamper Resistance + Trakt Credential Sync
    const cipher = await encryptVaultPayload(
      {
        customTmdbToken: 'tmdb_secret',
        trakt: { enabled: true, clientId: 'trakt_cid', accessToken: 'trakt_pat' }
      },
      env
    );
    const [ivPart, dataPart] = cipher.split('.');
    const tampered = `${ivPart}.${dataPart!.slice(0, -4)}AAAA`;
    assert.equal(await decryptVaultPayload(tampered, env), null);

    await writeProviderVault(f.db, env, {
      customTmdbToken: 'tmdb_secret',
      trakt: { enabled: true, clientId: 'trakt_cid', accessToken: 'trakt_pat' }
    });
    const vaultRead = await readProviderVault(f.db, env);
    assert.equal(vaultRead.settings?.trakt?.clientId, 'trakt_cid');
    assert.equal(vaultRead.settings?.trakt?.accessToken, 'trakt_pat');

    // 8. refreshTitleMetadata refreshes both series details AND latest-season episode air dates
    const mockTmdb = {
      details: async () => ({
        tmdbId: 209867,
        mediaType: 'tv' as const,
        imdbId: 'tt22248376',
        name: 'Frieren: Beyond Journey’s End',
        year: 2023,
        overview: 'Updated overview from TMDb.',
        posterPath: '/frieren-new.jpg',
        backdropPath: '/frieren-bg.jpg',
        runtimeMinutes: 24,
        genres: ['Animation', 'Fantasy'],
        communityScore: 8.9,
        seasons: [
          { number: 1, name: 'Season 1', expectedEpisodes: 28 },
          { number: 2, name: 'Season 2', expectedEpisodes: 2 }
        ]
      }),
      season: async (_id: number, seasonNum: number) =>
        seasonNum === 2
          ? [
              {
                number: 1,
                name: 'A New Journey',
                overview: 'Premiere',
                airedOn: '2026-10-25',
                tmdbId: 9001,
                stillPath: null,
                communityScore: 9.1
              },
              {
                number: 2,
                name: 'Northern Magic',
                overview: 'Episode 2',
                airedOn: '2026-11-01',
                tmdbId: 9002,
                stillPath: null,
                communityScore: 9.3
              }
            ]
          : []
    };

    const imported = await importTmdb(f.db, mockTmdb as never, {
      mediaType: 'tv',
      tmdbId: 209867,
      category: 'anime',
      status: 'watching'
    });
    const beforeRefreshIso = new Date(Date.now() - 1000).toISOString();
    const refreshed = await refreshTitleMetadata(f.db, mockTmdb as never, imported.title.id);
    assert.equal(refreshed.title.posterPath, '/frieren-new.jpg');

    const deltaAfterRefresh = await workspaceChanges(
      f.db,
      new URLSearchParams({ since: beforeRefreshIso }),
      readWorkspaceRevision
    );
    assert.equal(deltaAfterRefresh.fullRefreshRequired, false);
    assert.equal(
      deltaAfterRefresh.titles[0]!.poster,
      'https://image.tmdb.org/t/p/w500/frieren-new.jpg'
    );
    assert.equal(deltaAfterRefresh.episodes.length, 2);
    assert.equal(deltaAfterRefresh.episodes[0]!.airedOn, '2026-10-25');

    // 9. CSV Import with 0.5-star rating clamping [1, 10] and Archive Tags Delta Sync
    const halfStarCsv = [
      'Date,Name,Year,Rating,Watched Date',
      '2026-10-01,"Half Star Movie",2020,0.5,2026-10-01'
    ].join('\n');
    const halfStarArchive = parseExternalCsvToArchive(halfStarCsv);
    assert.equal(halfStarArchive.titles[0]!.personalRating, 1);
    assert.equal(halfStarArchive.titles[0]!.score, 1);
    (halfStarArchive.titles[0] as { tags?: string[] }).tags = ['Cult Classics', '2020s'];

    const beforeCsvIso = new Date(Date.now() - 1000).toISOString();
    const csvImportRes = await importDiaryArchive(f.db, halfStarArchive);
    assert.equal(csvImportRes.importedTitles, 1);

    const deltaAfterCsv = await workspaceChanges(
      f.db,
      new URLSearchParams({ since: beforeCsvIso }),
      readWorkspaceRevision
    );
    const importedHalfStar = deltaAfterCsv.titles.find((t) => t.name === 'Half Star Movie');
    assert.equal(importedHalfStar?.score, 1);
    assert.deepEqual(importedHalfStar?.tags, ['Cult Classics', '2020s']);

    // 10. Torture Test: 500 Series/Anime & 5,000 Episodes through AiringCalendar, .ics Export, and Tag Filtering
    const tortureDiary = sampleDiary();
    const base = tortureDiary.titles[0]!;
    tortureDiary.titles = Array.from({ length: 500 }, (_, i) => ({
      ...base,
      id: `series-${i}`,
      name: `Series, #${i}; "Special"`,
      category: i % 2 === 0 ? ('anime' as const) : ('show' as const),
      status: 'watching' as const,
      tags: i % 10 === 0 ? ['Simulcast', 'Top Priority'] : ['Backlog']
    }));
    tortureDiary.events = [];
    tortureDiary.skippedEpisodeIds = [];
    tortureDiary.episodes = Array.from({ length: 5000 }, (_, i) => {
      const dayOffset = (i % 40) - 10; // -10d to +29d
      const date = new Date(Date.UTC(2026, 9, 23 + dayOffset)).toISOString().slice(0, 10);
      return {
        id: `ep-${i}`,
        titleId: `series-${i % 500}`,
        season: 1,
        number: Math.floor(i / 500) + 1,
        name: `Episode ${i}; Part, 1`,
        overview: 'Line 1\nLine 2',
        airedOn: date
      };
    });

    const t0 = performance.now();
    const upcomingTorture = upcomingSchedule(tortureDiary, {
      now: new Date('2026-10-23T05:00:00Z'),
      timeZone: 'UTC',
      mode: 'upcoming',
      horizonDays: 30
    });
    const catchupTorture = upcomingSchedule(tortureDiary, {
      now: new Date('2026-10-23T05:00:00Z'),
      timeZone: 'UTC',
      mode: 'catchup',
      horizonDays: 10
    });
    const icsTorture = formatAiringCalendarICS(upcomingTorture, { hideSpoilers: false });
    const filteredByTag = filterLibrary(tortureDiary, {
      query: '',
      category: 'all',
      status: 'all',
      availability: 'all',
      disk: 'all',
      favorites: false,
      genre: 'all',
      tag: 'Simulcast',
      sort: 'title'
    });
    const elapsedMs = performance.now() - t0;

    assert.equal(upcomingTorture.items.length, 3750);
    assert.equal(catchupTorture.items.length, 1250);
    assert.equal(catchupTorture.counts.thisWeek, 875);
    assert.equal(catchupTorture.strip[0]!.daysAway, -1);
    assert.equal(catchupTorture.strip[0]!.total, 125);
    assert.equal(icsTorture.startsWith('BEGIN:VCALENDAR'), true);
    assert.equal(filteredByTag.length, 50);
    assert.equal(elapsedMs < 2000, true, `Torture suite took ${elapsedMs.toFixed(1)}ms`);
  } finally {
    globalThis.fetch = originalFetch;
    f.close();
  }
});







