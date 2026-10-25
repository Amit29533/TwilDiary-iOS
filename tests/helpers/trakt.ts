import { sealTrakt } from '../../src/lib/server/trakt-auth.ts';
import { traktConnections } from '../../src/lib/server/db/schema.ts';
import type { d1Fixture } from './d1.ts';
export const traktEnv = {
  TRAKT_CLIENT_ID: 'fixture-client-id-123456789',
  TRAKT_TOKEN_KEY: Buffer.alloc(32, 7).toString('base64url'),
  TMDB_ACCESS_TOKEN: 'fixture-tmdb'
};
export async function connectFixture(f: ReturnType<typeof d1Fixture>) {
  await f.db.insert(traktConnections).values({
    id: 'trakt',
    clientId: traktEnv.TRAKT_CLIENT_ID,
    accountId: 'fixture-account',
    username: 'owner',
    state: 'connected',
    ciphertext: await sealTrakt(
      {
        access_token: 'fixture-access-token-123456789',
        refresh_token: 'fixture-refresh-token-123456789',
        created_at: Math.floor(Date.now() / 1000),
        expires_in: 3600
      },
      traktEnv.TRAKT_TOKEN_KEY
    ),
    expiresAt: Date.now() + 3600000,
    updatedAt: new Date().toISOString()
  });
}
export function fakeTrakt() {
  const state = {
    history: [] as Record<string, any>[],
    movieRatings: new Map<number, number>(),
    showRatings: new Map<number, number>(),
    movieWatchlist: new Set<number>(),
    showWatchlist: new Set<number>(),
    version: 0,
    posts: [] as { path: string; body: any }[],
    lostHistoryResponse: false,
    missingPagination: false
  };
  const media = (id: number) => ({
    title: id === 42 ? 'Story' : 'A movie',
    year: 2023,
    ids: { tmdb: id, trakt: id === 42 ? 77 : 177 }
  });
  const json = (v: unknown, headers: Record<string, string> = {}) =>
    new Response(JSON.stringify(v), {
      headers: { 'Content-Type': 'application/json', ...headers }
    });
  const page = (values: unknown[], url: URL) => {
    const page = Number(url.searchParams.get('page') ?? 1),
      limit = Number(url.searchParams.get('limit') ?? 100);
    return json(
      values.slice((page - 1) * limit, page * limit),
      state.missingPagination
        ? {}
        : {
            'X-Pagination-Page': String(page),
            'X-Pagination-Page-Count': String(Math.ceil(values.length / limit)),
            'X-Pagination-Item-Count': String(values.length)
          }
    );
  };
  const transport: typeof fetch = async (input, init) => {
    const url = new URL(String(input)),
      path = url.pathname;
    if (url.origin !== 'https://api.trakt.tv') throw new Error('Unexpected fixture destination');
    if (init?.method === 'POST') {
      const body = JSON.parse(String(init.body));
      state.posts.push({ path, body });
      state.version++;
      if (path === '/sync/history') {
        for (const movie of body.movies ?? [])
          state.history.push({
            id: 9000 + state.history.length,
            type: 'movie',
            watched_at:
              movie.watched_at === 'unknown'
                ? null
                : new Date(movie.watched_at).toISOString().slice(0, 16) + ':00.000Z',
            movie: media(movie.ids.tmdb)
          });
        for (const show of body.shows ?? [])
          for (const season of show.seasons ?? [])
            for (const episode of season.episodes ?? [])
              state.history.push({
                id: 9000 + state.history.length,
                type: 'episode',
                watched_at:
                  episode.watched_at === 'unknown'
                    ? null
                    : new Date(episode.watched_at).toISOString().slice(0, 16) + ':00.000Z',
                show: media(show.ids.tmdb),
                episode: {
                  season: season.number,
                  number: episode.number,
                  ids: { trakt: 1000 + episode.number }
                }
              });
        if (state.lostHistoryResponse) {
          state.lostHistoryResponse = false;
          throw new Error('Lost fixture response');
        }
      } else if (path === '/sync/history/remove')
        state.history = state.history.filter(
          (row) => !body.ids.map(String).includes(String(row.id))
        );
      else
        for (const [bucket, ratings, watchlist] of [
          ['movies', state.movieRatings, state.movieWatchlist],
          ['shows', state.showRatings, state.showWatchlist]
        ] as const)
          for (const item of body[bucket] ?? []) {
            const id = item.ids.tmdb;
            if (path.startsWith('/sync/ratings')) {
              if (path.endsWith('/remove')) ratings.delete(id);
              else ratings.set(id, item.rating);
            } else if (path.startsWith('/sync/watchlist')) {
              if (path.endsWith('/remove')) watchlist.delete(id);
              else watchlist.add(id);
            }
          }
      return json({
        added: { movies: body.movies?.length ?? 0, episodes: body.shows?.length ?? 0 },
        not_found: {}
      });
    }
    if (path === '/sync/last_activities') {
      const value = new Date(Date.UTC(2026, 0, 1, 0, 0, state.version)).toISOString();
      return json({
        movies: { watched_at: value, rated_at: value, watchlisted_at: value },
        episodes: { watched_at: value },
        shows: { rated_at: value, watchlisted_at: value }
      });
    }
    if (path === '/sync/history') return page(state.history, url);
    if (path.startsWith('/sync/history/')) {
      const [, type, id] = path.match(/\/sync\/history\/(movies|episodes)\/(\d+)/)!;
      return page(
        state.history.filter((row) =>
          type === 'movies'
            ? row.type === 'movie' && row.movie.ids.trakt === Number(id)
            : row.type === 'episode' && row.episode.ids.trakt === Number(id)
        ),
        url
      );
    }
    if (path.startsWith('/sync/ratings/')) {
      const movies = path.endsWith('movies');
      return page(
        [...(movies ? state.movieRatings : state.showRatings)].map(([id, rating]) => ({
          rating,
          [movies ? 'movie' : 'show']: media(id)
        })),
        url
      );
    }
    if (path.startsWith('/sync/watchlist/')) {
      const movies = path.endsWith('movies');
      return page(
        [...(movies ? state.movieWatchlist : state.showWatchlist)].map((id) => ({
          [movies ? 'movie' : 'show']: media(id)
        })),
        url
      );
    }
    if (path.startsWith('/search/tmdb/')) {
      const id = Number(path.split('/').at(-1));
      return json([{ [url.searchParams.get('type') === 'movie' ? 'movie' : 'show']: media(id) }]);
    }
    if (path.startsWith('/shows/')) {
      const episode = Number(path.split('/').at(-1));
      return json({ ids: { trakt: 1000 + episode } });
    }
    throw new Error('Unhandled fixture endpoint ' + path);
  };
  return { state, transport, media };
}
export const fakeTmdb: typeof fetch = async (input) => {
  const url = new URL(String(input));
  if (url.origin !== 'https://api.themoviedb.org')
    throw new Error('Unexpected TMDB fixture destination');
  const season = url.pathname.includes('/season/');
  return new Response(
    JSON.stringify(
      season
        ? {
            season_number: 1,
            episodes: [1, 2].map((number) => ({
              id: 100 + number,
              season_number: 1,
              episode_number: number,
              name: 'Chapter ' + number,
              overview: 'Hidden synopsis',
              air_date: '2024-01-01',
              still_path: '/still.jpg'
            }))
          }
        : {
            id: Number(url.pathname.split('/').at(-1)),
            name: 'Story',
            title: 'A movie',
            first_air_date: '2023-01-01',
            release_date: '2023-01-01',
            original_language: 'ja',
            overview: 'Overview',
            genres: [{ name: 'Animation' }],
            seasons: [{ season_number: 1, name: 'Season 1', episode_count: 2 }],
            episode_run_time: [24],
            runtime: 120
          }
    ),
    { headers: { 'Content-Type': 'application/json' } }
  );
};
