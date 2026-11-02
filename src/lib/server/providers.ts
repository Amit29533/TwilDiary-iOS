import { and, eq } from 'drizzle-orm';
import { ApiError } from './api.ts';
import type { database } from './db/index.ts';
import { episodes, providerIdentities, seasons } from './db/schema.ts';
import { getTitle, logWatch, patchTitle } from './library.ts';

type Db = ReturnType<typeof database>;

export type ExternalProvider = 'trakt' | 'simkl' | 'mdblist' | 'wetrakr';

export type NormalizedRemotePlay = {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  season?: number;
  episode?: number;
  watchedAt: string;
};

export type NormalizedRemoteRating = {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  rating: number;
  ratedAt: string;
};

export type NormalizedRemoteWatchlist = {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  listedAt: string;
};

export type NormalizedRemoteFavorite = {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  favoritedAt: string;
  removed?: boolean;
};

export type NormalizedRemoteDropped = {
  tmdbId: number;
  mediaType: 'tv';
  droppedAt: string;
};

export type NormalizedProviderSnapshot = {
  provider: ExternalProvider;
  plays: NormalizedRemotePlay[];
  ratings: Array<NormalizedRemoteRating & { removed?: boolean }>;
  watchlist: NormalizedRemoteWatchlist[];
  favorites?: NormalizedRemoteFavorite[];
  dropped?: NormalizedRemoteDropped[];
};

export type WeTrakrActivitySection = {
  all: string | null;
  ratedAt: string | null;
  favoritedAt: string | null;
  planningAt: string | null;
  watchedAt: string | null;
  droppedAt: string | null;
  removedAt: string | null;
  playbackAt: string | null;
};

export type WeTrakrActivities = {
  movies: WeTrakrActivitySection;
  shows: WeTrakrActivitySection;
  episodes: WeTrakrActivitySection;
  ratings: WeTrakrActivitySection;
  favorites: WeTrakrActivitySection;
};

export type MDBListRatingSource = {
  source: string;
  value: number | null;
  score: number | null;
  votes: number | null;
};

export type MDBListSummary = {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  score: number | null;
  ratings: MDBListRatingSource[];
};

const parseTmdbId = (value: unknown): number | null => {
  if (typeof value === 'number' && Number.isInteger(value) && value > 0) return value;
  if (typeof value === 'string' && /^\d+$/.test(value)) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
  }
  return null;
};

/**
 * Normalizes Simkl's `GET https://api.simkl.com/sync/all-items/` response (`movies`, `shows`, `anime`)
 * into TMDb-keyed plays, ratings, and watchlist items.
 */
export const normalizeSimklAllItems = (raw: unknown): NormalizedProviderSnapshot => {
  const payload = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const movies = Array.isArray(payload.movies) ? payload.movies : [];
  const shows = Array.isArray(payload.shows) ? payload.shows : [];
  const anime = Array.isArray(payload.anime) ? payload.anime : [];

  const plays: NormalizedRemotePlay[] = [];
  const ratings: NormalizedRemoteRating[] = [];
  const watchlist: NormalizedRemoteWatchlist[] = [];

  for (const row of movies) {
    if (!row || typeof row !== 'object') continue;
    const item = row as Record<string, unknown>;
    const movie = item.movie && typeof item.movie === 'object' ? (item.movie as Record<string, unknown>) : null;
    const ids = movie?.ids && typeof movie.ids === 'object' ? (movie.ids as Record<string, unknown>) : null;
    const tmdbId = parseTmdbId(ids?.tmdb);
    if (!tmdbId) continue;

    if (item.status === 'completed' && typeof item.last_watched_at === 'string') {
      plays.push({ tmdbId, mediaType: 'movie', watchedAt: item.last_watched_at });
    }
    if (typeof item.user_rating === 'number' && item.user_rating >= 1 && item.user_rating <= 10) {
      ratings.push({
        tmdbId,
        mediaType: 'movie',
        rating: Math.round(item.user_rating),
        ratedAt:
          (typeof item.user_rated_at === 'string' && item.user_rated_at) ||
          (typeof item.last_watched_at === 'string' && item.last_watched_at) ||
          new Date(0).toISOString()
      });
    }
    if (item.status === 'plantowatch') {
      watchlist.push({
        tmdbId,
        mediaType: 'movie',
        listedAt:
          (typeof item.added_to_watchlist_at === 'string' && item.added_to_watchlist_at) ||
          new Date(0).toISOString()
      });
    }
  }

  for (const row of [...shows, ...anime]) {
    if (!row || typeof row !== 'object') continue;
    const item = row as Record<string, unknown>;
    const show = item.show && typeof item.show === 'object' ? (item.show as Record<string, unknown>) : null;
    const ids = show?.ids && typeof show.ids === 'object' ? (show.ids as Record<string, unknown>) : null;
    const tmdbId = parseTmdbId(ids?.tmdb);
    if (!tmdbId) continue;

    const seasons = Array.isArray(item.seasons) ? item.seasons : [];
    for (const sRow of seasons) {
      if (!sRow || typeof sRow !== 'object') continue;
      const seasonObj = sRow as Record<string, unknown>;
      const seasonNum = typeof seasonObj.number === 'number' ? seasonObj.number : null;
      if (seasonNum === null) continue;
      const episodes = Array.isArray(seasonObj.episodes) ? seasonObj.episodes : [];
      for (const eRow of episodes) {
        if (!eRow || typeof eRow !== 'object') continue;
        const epObj = eRow as Record<string, unknown>;
        const epNum = typeof epObj.number === 'number' ? epObj.number : null;
        if (epNum === null) continue;
        plays.push({
          tmdbId,
          mediaType: 'tv',
          season: seasonNum,
          episode: epNum,
          watchedAt:
            (typeof epObj.watched_at === 'string' && epObj.watched_at) ||
            (typeof item.last_watched_at === 'string' && item.last_watched_at) ||
            new Date(0).toISOString()
        });
      }
    }

    if (typeof item.user_rating === 'number' && item.user_rating >= 1 && item.user_rating <= 10) {
      ratings.push({
        tmdbId,
        mediaType: 'tv',
        rating: Math.round(item.user_rating),
        ratedAt:
          (typeof item.user_rated_at === 'string' && item.user_rated_at) ||
          (typeof item.last_watched_at === 'string' && item.last_watched_at) ||
          new Date(0).toISOString()
      });
    }
    if (item.status === 'plantowatch') {
      watchlist.push({
        tmdbId,
        mediaType: 'tv',
        listedAt:
          (typeof item.added_to_watchlist_at === 'string' && item.added_to_watchlist_at) ||
          new Date(0).toISOString()
      });
    }
  }

  return { provider: 'simkl', plays, ratings, watchlist };
};

/**
 * Normalizes MDBList (`GET https://api.mdblist.com/tmdb/{movie|show}/{tmdbId}`) multi-source ratings.
 */
export const normalizeMDBListSummary = (
  raw: unknown,
  tmdbId: number,
  mediaType: 'movie' | 'tv'
): MDBListSummary => {
  const payload = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const score = typeof payload.score === 'number' ? payload.score : null;
  const rows = Array.isArray(payload.ratings) ? payload.ratings : [];
  const ratings: MDBListRatingSource[] = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const r = row as Record<string, unknown>;
    if (typeof r.source !== 'string') continue;
    ratings.push({
      source: r.source,
      value: typeof r.value === 'number' ? r.value : null,
      score: typeof r.score === 'number' ? r.score : null,
      votes: typeof r.votes === 'number' ? r.votes : null
    });
  }
  return { tmdbId, mediaType, score, ratings };
};

const parseActivitySection = (raw: unknown): WeTrakrActivitySection => {
  const sec = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const str = (key: string) => (typeof sec[key] === 'string' && sec[key] ? (sec[key] as string) : null);
  return {
    all: str('all'),
    ratedAt: str('last_rated_at'),
    favoritedAt: str('last_favorited_at'),
    planningAt: str('last_tracking_planning_at'),
    watchedAt: str('last_tracking_watched_at'),
    droppedAt: str('last_tracking_dropped_at'),
    removedAt: str('last_tracking_removed_at'),
    playbackAt: str('last_playback_at')
  };
};

/**
 * Parses WeTrakr's `GET https://api.wetrakr.com/sync/last_activities` response.
 */
export const parseWeTrakrActivities = (raw: unknown): WeTrakrActivities => {
  const payload = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  return {
    movies: parseActivitySection(payload.movies),
    shows: parseActivitySection(payload.shows),
    episodes: parseActivitySection(payload.episodes),
    ratings: parseActivitySection(payload.ratings),
    favorites: parseActivitySection(payload.favorites)
  };
};

/**
 * Compares WeTrakr activity timestamps against a saved checkpoint so only changed lists are fetched.
 */
export const changedWeTrakrDomains = (
  current: WeTrakrActivities,
  previous: WeTrakrActivities | null
) => {
  if (!previous) {
    return {
      watchedMovies: true,
      watchedEpisodes: true,
      watchlist: true,
      dropped: true,
      ratings: true,
      favorites: true,
      anyChanged: true
    };
  }
  const watchedMovies = current.movies.watchedAt !== previous.movies.watchedAt;
  const watchedEpisodes = current.episodes.watchedAt !== previous.episodes.watchedAt;
  const watchlist =
    current.movies.planningAt !== previous.movies.planningAt ||
    current.movies.removedAt !== previous.movies.removedAt ||
    current.shows.planningAt !== previous.shows.planningAt ||
    current.shows.removedAt !== previous.shows.removedAt;
  const dropped =
    current.shows.droppedAt !== previous.shows.droppedAt ||
    current.shows.removedAt !== previous.shows.removedAt;
  const ratings = current.ratings.all !== previous.ratings.all;
  const favorites = current.favorites.all !== previous.favorites.all;
  return {
    watchedMovies,
    watchedEpisodes,
    watchlist,
    dropped,
    ratings,
    favorites,
    anyChanged: watchedMovies || watchedEpisodes || watchlist || dropped || ratings || favorites
  };
};

/**
 * Normalizes WeTrakr compact rows (`?compact=true`) across watched, planning, ratings, favorites,
 * and dropped lists into TMDb-keyed items.
 */
export const normalizeWeTrakrCompactRows = (input: {
  watchedMovies?: unknown[];
  watchedEpisodes?: unknown[];
  planningMovies?: unknown[];
  planningShows?: unknown[];
  ratingsMovies?: unknown[];
  ratingsShows?: unknown[];
  favoritesMovies?: unknown[];
  favoritesShows?: unknown[];
  droppedShows?: unknown[];
}): NormalizedProviderSnapshot => {
  const plays: NormalizedRemotePlay[] = [];
  const ratings: Array<NormalizedRemoteRating & { removed?: boolean }> = [];
  const watchlist: NormalizedRemoteWatchlist[] = [];
  const favorites: NormalizedRemoteFavorite[] = [];
  const dropped: NormalizedRemoteDropped[] = [];

  const extractTmdb = (row: Record<string, unknown>, preferShow = false): number | null => {
    if (preferShow && row.show_ids && typeof row.show_ids === 'object') {
      const showTmdb = parseTmdbId((row.show_ids as Record<string, unknown>).tmdb);
      if (showTmdb) return showTmdb;
    }
    if (row.ids && typeof row.ids === 'object') {
      return parseTmdbId((row.ids as Record<string, unknown>).tmdb);
    }
    return null;
  };

  const firstTimestamp = (row: Record<string, unknown>, ...keys: string[]): string => {
    for (const key of keys) {
      const val = row[key];
      if (typeof val === 'string' && val) return val;
    }
    return new Date(0).toISOString();
  };

  for (const raw of input.watchedMovies ?? []) {
    if (!raw || typeof raw !== 'object') continue;
    const row = raw as Record<string, unknown>;
    const tmdbId = extractTmdb(row);
    if (!tmdbId) continue;
    plays.push({
      tmdbId,
      mediaType: 'movie',
      watchedAt: firstTimestamp(row, 'last_watched_at', 'watched_at', 'tracked_at')
    });
  }

  for (const raw of input.watchedEpisodes ?? []) {
    if (!raw || typeof raw !== 'object') continue;
    const row = raw as Record<string, unknown>;
    const tmdbId = extractTmdb(row, true);
    const season = typeof row.season_number === 'number' ? row.season_number : null;
    const episode = typeof row.number === 'number' ? row.number : null;
    if (!tmdbId || season === null || episode === null || episode <= 0) continue;
    plays.push({
      tmdbId,
      mediaType: 'tv',
      season,
      episode,
      watchedAt: firstTimestamp(row, 'last_watched_at', 'watched_at', 'tracked_at')
    });
  }

  for (const [rows, mediaType] of [
    [input.planningMovies ?? [], 'movie'],
    [input.planningShows ?? [], 'tv']
  ] as const) {
    for (const raw of rows) {
      if (!raw || typeof raw !== 'object') continue;
      const row = raw as Record<string, unknown>;
      if (row.status === 'removed') continue;
      const tmdbId = extractTmdb(row);
      if (!tmdbId) continue;
      watchlist.push({
        tmdbId,
        mediaType,
        listedAt: firstTimestamp(row, 'tracked_at')
      });
    }
  }

  for (const [rows, mediaType] of [
    [input.ratingsMovies ?? [], 'movie'],
    [input.ratingsShows ?? [], 'tv']
  ] as const) {
    for (const raw of rows) {
      if (!raw || typeof raw !== 'object') continue;
      const row = raw as Record<string, unknown>;
      const tmdbId = extractTmdb(row);
      if (!tmdbId) continue;
      if (row.status === 'removed') {
        ratings.push({
          tmdbId,
          mediaType,
          rating: 0,
          ratedAt: firstTimestamp(row, 'removed_at', 'rated_at'),
          removed: true
        });
        continue;
      }
      if (typeof row.rating === 'number' && row.rating > 0 && row.rating <= 10) {
        ratings.push({
          tmdbId,
          mediaType,
          rating: Math.round(row.rating * 10) / 10,
          ratedAt: firstTimestamp(row, 'rated_at')
        });
      }
    }
  }

  for (const [rows, mediaType] of [
    [input.favoritesMovies ?? [], 'movie'],
    [input.favoritesShows ?? [], 'tv']
  ] as const) {
    for (const raw of rows) {
      if (!raw || typeof raw !== 'object') continue;
      const row = raw as Record<string, unknown>;
      const tmdbId = extractTmdb(row);
      if (!tmdbId) continue;
      const removed = row.status === 'removed';
      favorites.push({
        tmdbId,
        mediaType,
        favoritedAt: firstTimestamp(row, removed ? 'removed_at' : 'favorited_at', 'favorited_at'),
        ...(removed ? { removed: true } : {})
      });
    }
  }

  for (const raw of input.droppedShows ?? []) {
    if (!raw || typeof raw !== 'object') continue;
    const row = raw as Record<string, unknown>;
    if (row.status === 'removed') continue;
    const tmdbId = extractTmdb(row);
    if (!tmdbId) continue;
    dropped.push({
      tmdbId,
      mediaType: 'tv',
      droppedAt: firstTimestamp(row, 'tracked_at')
    });
  }

  return { provider: 'wetrakr', plays, ratings, watchlist, favorites, dropped };
};

/**
 * Builds outbound sync payloads for Trakt, Simkl, MDBList, or WeTrakr from normalized items.
 */
export const buildOutboundProviderPayloads = (
  provider: ExternalProvider,
  input: {
    plays?: NormalizedRemotePlay[];
    ratings?: NormalizedRemoteRating[];
    watchlist?: NormalizedRemoteWatchlist[];
    favorites?: NormalizedRemoteFavorite[];
    dropped?: NormalizedRemoteDropped[];
    allowRewatch?: boolean;
  }
) => {
  const isWeTrakr = provider === 'wetrakr';
  const moviesHistory: Array<Record<string, unknown>> = [];
  const showsMap = new Map<number, Map<number, Array<Record<string, unknown>>>>();

  for (const play of input.plays ?? []) {
    if (play.mediaType === 'movie') {
      moviesHistory.push(
        isWeTrakr
          ? { status: 'watched', tracked_at: play.watchedAt, ids: { tmdb: play.tmdbId } }
          : { watched_at: play.watchedAt, ids: { tmdb: play.tmdbId } }
      );
    } else if (typeof play.season === 'number' && typeof play.episode === 'number') {
      let seasons = showsMap.get(play.tmdbId);
      if (!seasons) {
        seasons = new Map();
        showsMap.set(play.tmdbId, seasons);
      }
      const list = seasons.get(play.season) ?? [];
      list.push(
        isWeTrakr
          ? { number: play.episode, status: 'watched', tracked_at: play.watchedAt }
          : { number: play.episode, watched_at: play.watchedAt }
      );
      seasons.set(play.season, list);
    }
  }

  const showsHistory = [...showsMap.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([tmdbId, seasons]) => ({
      ids: { tmdb: tmdbId },
      seasons: [...seasons.entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([number, episodes]) => ({ number, episodes }))
    }));

  const ratedMovies = (input.ratings ?? [])
    .filter((r) => r.mediaType === 'movie')
    .map((r) =>
      isWeTrakr
        ? { rating: r.rating, ids: { tmdb: r.tmdbId } }
        : { rating: r.rating, rated_at: r.ratedAt, ids: { tmdb: r.tmdbId } }
    );
  const ratedShows = (input.ratings ?? [])
    .filter((r) => r.mediaType === 'tv')
    .map((r) =>
      isWeTrakr
        ? { rating: r.rating, ids: { tmdb: r.tmdbId } }
        : { rating: r.rating, rated_at: r.ratedAt, ids: { tmdb: r.tmdbId } }
    );

  const watchlistMovies = (input.watchlist ?? [])
    .filter((w) => w.mediaType === 'movie')
    .map((w) =>
      provider === 'simkl'
        ? { to: 'plantowatch', ids: { tmdb: w.tmdbId } }
        : isWeTrakr
          ? { status: 'planning', ids: { tmdb: w.tmdbId } }
          : { ids: { tmdb: w.tmdbId } }
    );
  const watchlistShows = [
    ...(input.watchlist ?? [])
      .filter((w) => w.mediaType === 'tv')
      .map((w) =>
        provider === 'simkl'
          ? { to: 'plantowatch', ids: { tmdb: w.tmdbId } }
          : isWeTrakr
            ? { status: 'planning', ids: { tmdb: w.tmdbId } }
            : { ids: { tmdb: w.tmdbId } }
      ),
    ...(isWeTrakr
      ? (input.dropped ?? []).map((d) => ({ status: 'dropped', ids: { tmdb: d.tmdbId } }))
      : [])
  ];

  const favoriteMovies = (input.favorites ?? [])
    .filter((f) => f.mediaType === 'movie' && !f.removed)
    .map((f) => ({ ids: { tmdb: f.tmdbId } }));
  const favoriteShows = (input.favorites ?? [])
    .filter((f) => f.mediaType === 'tv' && !f.removed)
    .map((f) => ({ ids: { tmdb: f.tmdbId } }));

  return {
    history:
      moviesHistory.length || showsHistory.length
        ? {
            movies: moviesHistory,
            shows: showsHistory,
            ...(isWeTrakr ? { allow_rewatch: input.allowRewatch ?? true } : {})
          }
        : null,
    ratings:
      ratedMovies.length || ratedShows.length
        ? { movies: ratedMovies, shows: ratedShows }
        : null,
    watchlist:
      watchlistMovies.length || watchlistShows.length
        ? { movies: watchlistMovies, shows: watchlistShows }
        : null,
    favorites:
      favoriteMovies.length || favoriteShows.length
        ? { movies: favoriteMovies, shows: favoriteShows }
        : null
  };
};

export interface ProviderPullCredentials {
  clientId?: string | undefined;
  accessToken?: string | undefined;
  apiKey?: string | undefined;
}

export interface ProviderSyncResult {
  provider: ExternalProvider;
  importedPlays: number;
  updatedRatings: number;
  updatedFavorites: number;
  updatedStatuses: number;
  syncedAt: string;
}

/**
 * Applies a normalized remote provider snapshot (`wetrakr`, `simkl`, `trakt`) into the D1 diary
 * idempotently for all matching TMDb titles already in the user's library.
 */
export async function applyNormalizedProviderSnapshotToDiary(
  db: Db,
  snapshot: NormalizedProviderSnapshot
): Promise<ProviderSyncResult> {
  const tmdbLinks = await db
    .select({
      titleId: providerIdentities.titleId,
      kind: providerIdentities.kind,
      externalId: providerIdentities.externalId
    })
    .from(providerIdentities)
    .where(eq(providerIdentities.provider, 'tmdb'))
    .all();

  const titleIdByTmdbKey = new Map<string, string>();
  for (const row of tmdbLinks) {
    titleIdByTmdbKey.set(`${row.kind}:${row.externalId}`, row.titleId);
  }

  let importedPlays = 0;
  let updatedRatings = 0;
  let updatedFavorites = 0;
  let updatedStatuses = 0;

  for (const play of snapshot.plays) {
    const kind = play.mediaType === 'movie' ? 'movie' : 'series';
    const titleId = titleIdByTmdbKey.get(`${kind}:${play.tmdbId}`);
    if (!titleId) continue;

    let episodeId: string | null = null;
    if (kind === 'series') {
      if (typeof play.season !== 'number' || typeof play.episode !== 'number') continue;
      const ep = await db
        .select({ id: episodes.id })
        .from(episodes)
        .innerJoin(seasons, eq(seasons.id, episodes.seasonId))
        .where(
          and(
            eq(episodes.titleId, titleId),
            eq(seasons.number, play.season),
            eq(episodes.number, play.episode)
          )
        )
        .get();
      if (!ep) continue;
      episodeId = ep.id;
    }

    const cleanStamp = play.watchedAt.replace(/[^a-zA-Z0-9_-]/g, '_');
    const opId = `provider-${snapshot.provider}-${kind}-${play.tmdbId}-${play.season ?? 0}-${play.episode ?? 0}-${cleanStamp}`.slice(
      0,
      120
    );
    try {
      const res = await logWatch(db, titleId, {
        operationId: opId,
        episodeId,
        watchedAt: play.watchedAt,
        rewatch: false
      });
      if (res.added) importedPlays++;
    } catch {
      /* Ignore future/un-aired or deleted title watch conflicts */
    }
  }

  for (const rating of snapshot.ratings) {
    if (rating.removed) continue;
    const kind = rating.mediaType === 'movie' ? 'movie' : 'series';
    const titleId = titleIdByTmdbKey.get(`${kind}:${rating.tmdbId}`);
    if (!titleId) continue;
    try {
      const current = await getTitle(db, titleId);
      const cleanScore = Math.max(1, Math.min(10, Math.round(rating.rating * 10) / 10));
      if (current.score === null) {
        await patchTitle(db, titleId, {
          expectedVersion: current.version,
          score: cleanScore
        });
        updatedRatings++;
      }
    } catch {
      /* Ignore concurrent version conflict */
    }
  }

  for (const fav of snapshot.favorites ?? []) {
    if (fav.removed) continue;
    const kind = fav.mediaType === 'movie' ? 'movie' : 'series';
    const titleId = titleIdByTmdbKey.get(`${kind}:${fav.tmdbId}`);
    if (!titleId) continue;
    try {
      const current = await getTitle(db, titleId);
      if (!current.favorite) {
        await patchTitle(db, titleId, {
          expectedVersion: current.version,
          favorite: true
        });
        updatedFavorites++;
      }
    } catch {
      /* Ignore concurrent version conflict */
    }
  }

  for (const item of snapshot.watchlist) {
    const kind = item.mediaType === 'movie' ? 'movie' : 'series';
    const titleId = titleIdByTmdbKey.get(`${kind}:${item.tmdbId}`);
    if (!titleId) continue;
    try {
      const current = await getTitle(db, titleId);
      if (!current.queued && current.status === 'planned') {
        await patchTitle(db, titleId, {
          expectedVersion: current.version,
          queued: true
        });
        updatedStatuses++;
      }
    } catch {
      /* Ignore concurrent version conflict */
    }
  }

  for (const drop of snapshot.dropped ?? []) {
    const titleId = titleIdByTmdbKey.get(`series:${drop.tmdbId}`);
    if (!titleId) continue;
    try {
      const current = await getTitle(db, titleId);
      if (current.status !== 'dropped') {
        await patchTitle(db, titleId, {
          expectedVersion: current.version,
          status: 'dropped'
        });
        updatedStatuses++;
      }
    } catch {
      /* Ignore concurrent version conflict */
    }
  }

  return {
    provider: snapshot.provider,
    importedPlays,
    updatedRatings,
    updatedFavorites,
    updatedStatuses,
    syncedAt: new Date().toISOString()
  };
}

/**
 * Fetches remote watched history, ratings, favorites, and watchlist from an external provider
 * (`wetrakr` or `simkl`) and merges them into the user's D1 library.
 */
export async function syncExternalProviderWithDiary(
  db: Db,
  provider: ExternalProvider,
  credentials: ProviderPullCredentials,
  transport: typeof fetch = fetch
): Promise<ProviderSyncResult> {
  const clientId = credentials.clientId?.trim() ?? '';
  const accessToken = credentials.accessToken?.trim() ?? '';

  if (provider === 'simkl') {
    if (!clientId || !accessToken) {
      throw new ApiError(400, 'invalid_credentials', 'Simkl Client ID and Access Token are required.');
    }
    const res = await transport('https://api.simkl.com/sync/all-items/', {
      headers: {
        Accept: 'application/json',
        'simkl-api-key': clientId,
        Authorization: `Bearer ${accessToken}`
      },
      redirect: 'manual'
    });
    if (!res.ok) {
      throw new ApiError(502, 'provider_unavailable', `Simkl sync returned HTTP ${res.status}.`);
    }
    const raw = await res.json();
    const snapshot = normalizeSimklAllItems(raw);
    return applyNormalizedProviderSnapshotToDiary(db, snapshot);
  }

  if (provider === 'wetrakr') {
    if (!clientId || !accessToken) {
      throw new ApiError(
        400,
        'invalid_credentials',
        'WeTrakr App API Key and Access Token / PAT are required.'
      );
    }
    const headers = {
      Accept: 'application/json',
      'wetrakr-api-version': '1',
      'wetrakr-api-key': clientId,
      Authorization: `Bearer ${accessToken}`
    };
    const fetchRows = async (path: string): Promise<unknown[]> => {
      const res = await transport(`https://api.wetrakr.com${path}`, {
        headers,
        redirect: 'manual'
      });
      if (!res.ok) throw new ApiError(502, 'provider_unavailable', `WeTrakr returned HTTP ${res.status}.`);
      const parsed = await res.json();
      return Array.isArray(parsed) ? parsed : [];
    };
    const [
      watchedMovies,
      watchedEpisodes,
      ratingsMovies,
      ratingsShows,
      planningMovies,
      planningShows,
      favoritesMovies,
      favoritesShows,
      droppedShows
    ] = await Promise.all([
      fetchRows('/sync/watched/movies'),
      fetchRows('/sync/watched/episodes'),
      fetchRows('/sync/ratings/movies'),
      fetchRows('/sync/ratings/shows'),
      fetchRows('/sync/watchlist/movies'),
      fetchRows('/sync/watchlist/shows'),
      fetchRows('/sync/favorites/movies'),
      fetchRows('/sync/favorites/shows'),
      fetchRows('/sync/dropped/shows')
    ]);
    const snapshot = normalizeWeTrakrCompactRows({
      watchedMovies,
      watchedEpisodes,
      ratingsMovies,
      ratingsShows,
      planningMovies,
      planningShows,
      favoritesMovies,
      favoritesShows,
      droppedShows
    });
    return applyNormalizedProviderSnapshotToDiary(db, snapshot);
  }

  return {
    provider,
    importedPlays: 0,
    updatedRatings: 0,
    updatedFavorites: 0,
    updatedStatuses: 0,
    syncedAt: new Date().toISOString()
  };
}
