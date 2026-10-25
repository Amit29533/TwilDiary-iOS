import { ApiError } from './api.ts';
import type { CastMember } from '../domain/types.ts';
import type { PersonDetails, PersonCredit } from '../people.ts';
import { tmdbImage, searchQuery, type SearchMatch, type SearchPage } from '../metadata.ts';
import {
  discoveryGenres,
  type DiscoveryQuery,
  type DiscoveryItem,
  type DiscoveryPage
} from '../discovery.ts';

type RecordValue = Record<string, unknown>;
const record = (value: unknown): RecordValue => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw upstream();
  return value as RecordValue;
};
const upstream = () =>
  new ApiError(502, 'metadata_unavailable', 'TMDb returned incomplete metadata. Please try again.');
const int = (value: unknown, min: number, max: number) => {
  if (!Number.isSafeInteger(value) || (value as number) < min || (value as number) > max)
    throw upstream();
  return value as number;
};
const text = (value: unknown, max: number) =>
  typeof value === 'string' ? value.trim().slice(0, max) : '';
const path = (value: unknown) => (typeof value === 'string' && tmdbImage(value) ? value : null);
const date = (value: unknown) => {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const parsed = new Date(value + 'T00:00:00Z');
  return Number.isFinite(+parsed) && parsed.toISOString().slice(0, 10) === value ? value : null;
};
export function providerInput(type: unknown, id: unknown) {
  if ((type !== 'movie' && type !== 'tv') || !/^\d{1,10}$/.test(String(id)) || +String(id) < 1)
    throw new ApiError(400, 'invalid_input', 'Choose a movie or show from the search results');
  return { mediaType: type, id: +String(id) } as const;
}
export function personInput(id: unknown) {
  if (!/^\d{1,10}$/.test(String(id)) || +String(id) < 1)
    throw new ApiError(400, 'invalid_input', 'Choose a valid person');
  return +String(id);
}
function match(value: unknown, type?: 'movie' | 'tv'): SearchMatch | null {
  const item = record(value);
  const mediaType = type ?? item.media_type;
  if (mediaType !== 'movie' && mediaType !== 'tv') return null;
  const name = text(mediaType === 'movie' ? item.title : item.name, 300);
  if (!name) return null;
  const released = date(mediaType === 'movie' ? item.release_date : item.first_air_date);
  return {
    id: int(item.id, 1, 9999999999),
    mediaType,
    name,
    year: released ? +released.slice(0, 4) : null,
    overview: text(item.overview, 20000),
    posterPath: path(item.poster_path)
  };
}
export function createTmdb(
  token: string | undefined,
  transport: typeof fetch = fetch,
  options: { maxResponseBytes?: number } = {}
) {
  async function request(endpoint: string, params: Record<string, string> = {}) {
    if (!token?.trim())
      throw new ApiError(
        503,
        'metadata_setup_required',
        'TMDb search is not connected yet. You can still add a title manually.'
      );
    const url = new URL('https://api.themoviedb.org/3/' + endpoint);
    for (const [key, value] of Object.entries({ language: 'en-US', ...params }))
      url.searchParams.set(key, value);
    try {
      const response = await transport(url, {
        headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
        signal: AbortSignal.timeout(8000),
        // Do not follow redirects with the bearer token; Workers does not support "error".
        redirect: 'manual'
      });
      if (response.status === 429)
        throw new ApiError(
          429,
          'metadata_rate_limited',
          'TMDb is busy. Wait a moment before searching again.'
        );
      if (response.status === 404)
        throw new ApiError(
          404,
          'metadata_not_found',
          'This title or season is no longer available on TMDb'
        );
      if (response.status === 401 || response.status === 403)
        throw new ApiError(
          503,
          'metadata_setup_required',
          'The TMDb connection needs attention. You can add a title manually.'
        );
      if (!response.ok) throw upstream();
      // Bound upstream data as well as browser writes. Never expose an upstream error body/token.
      const reader = response.body?.getReader();
      if (!reader) throw upstream();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > Math.min(2_000_000, options.maxResponseBytes ?? 2_000_000)) {
            await reader.cancel();
            throw upstream();
          }
          chunks.push(value);
        }
      } finally {
        reader.releaseLock();
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      return record(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)));
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError(502, 'metadata_unavailable', 'Could not reach TMDb. Please try again.');
    }
  }
  return {
    async person(id: number): Promise<PersonDetails> {
      personInput(id);
      const data = await request(`person/${id}`, { append_to_response: 'combined_credits' });
      if (int(data.id, 1, 9999999999) !== id || !text(data.name, 200)) throw upstream();
      const combined = record(data.combined_credits);
      if (
        !Array.isArray(combined.cast) ||
        !Array.isArray(combined.crew) ||
        combined.cast.length + combined.crew.length > 10000
      )
        throw upstream();
      const credits = new Map<string, PersonCredit>();
      for (const value of [...combined.cast, ...combined.crew]) {
        if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
        const item = value as RecordValue;
        if (
          item.adult === true ||
          !Number.isSafeInteger(item.id) ||
          Number(item.id) < 1 ||
          Number(item.id) > 9999999999
        )
          continue;
        const base = match(value);
        if (!base) continue;
        const key = `${base.mediaType}:${base.id}`;
        const existing = credits.get(key);
        const character = text(item.character, 300),
          job = text(item.job, 200);
        if (existing) {
          if (character && !existing.character.split(' / ').includes(character))
            existing.character = [existing.character, character]
              .filter(Boolean)
              .join(' / ')
              .slice(0, 600);
          if (job && !existing.job.split(' / ').includes(job))
            existing.job = [existing.job, job].filter(Boolean).join(' / ').slice(0, 400);
          continue;
        }
        credits.set(key, {
          ...base,
          character,
          job,
          backdropPath: path(item.backdrop_path),
          rating:
            typeof item.vote_average === 'number' &&
            item.vote_average > 0 &&
            item.vote_average <= 10
              ? item.vote_average
              : null,
          votes:
            Number.isSafeInteger(item.vote_count) && Number(item.vote_count) >= 0
              ? Number(item.vote_count)
              : 0,
          popularity:
            typeof item.popularity === 'number' &&
            Number.isFinite(item.popularity) &&
            item.popularity >= 0
              ? item.popularity
              : 0,
          episodeCount:
            Number.isSafeInteger(item.episode_count) && Number(item.episode_count) > 0
              ? Number(item.episode_count)
              : null,
          genres: discoveryGenres
            .filter(
              (genre) =>
                Array.isArray(item.genre_ids) &&
                genre[base.mediaType] !== null &&
                item.genre_ids.includes(genre[base.mediaType])
            )
            .map((genre) => genre.name),
          source: 'tmdb'
        });
      }
      return {
        id,
        name: text(data.name, 200),
        biography: text(data.biography, 30000),
        birthday: date(data.birthday),
        deathday: date(data.deathday),
        birthplace: text(data.place_of_birth, 300),
        department: text(data.known_for_department, 100),
        profilePath: path(data.profile_path),
        aliases: [
          ...new Set(
            (Array.isArray(data.also_known_as) ? data.also_known_as : [])
              .map((value) => text(value, 200))
              .filter(Boolean)
          )
        ].slice(0, 20),
        credits: [...credits.values()]
      };
    },
    async cast(mediaType: 'movie' | 'tv', id: number): Promise<CastMember[]> {
      providerInput(mediaType, id);
      const data = await request(
        `${mediaType}/${id}/${mediaType === 'tv' ? 'aggregate_credits' : 'credits'}`
      );
      if (!Array.isArray(data.cast) || data.cast.length > 5000) throw upstream();
      const seen = new Set<number>();
      return data.cast
        .flatMap((value) => {
          if (!value || typeof value !== 'object') return [];
          const actor = value as RecordValue;
          if (
            !Number.isSafeInteger(actor.id) ||
            Number(actor.id) < 1 ||
            Number(actor.id) > 9999999999 ||
            seen.has(Number(actor.id))
          )
            return [];
          const name = text(actor.name, 200);
          if (!name) return [];
          seen.add(Number(actor.id));
          const roles = Array.isArray(actor.roles)
            ? (actor.roles
                .filter((role) => role && typeof role === 'object')
                .slice(0, 100) as RecordValue[])
            : [];
          const mainRole = roles.toSorted(
            (a, b) => Number(b.episode_count || 0) - Number(a.episode_count || 0)
          )[0];
          return [
            {
              id: Number(actor.id),
              name,
              character: text(actor.character ?? mainRole?.character, 200),
              profilePath: path(actor.profile_path)
            }
          ];
        })
        .slice(0, 24);
    },
    async discover(input: DiscoveryQuery, seedId?: number): Promise<DiscoveryPage> {
      if (input.source === 'because') providerInput(input.type, seedId);
      const genre = discoveryGenres.find((g) => g.name === input.genre);
      const params: Record<string, string> = { page: String(input.page), include_adult: 'false' };
      if (input.source !== 'because') {
        params.sort_by =
          input.sort === 'rating'
            ? 'vote_average.desc'
            : input.sort === 'newest'
              ? input.type === 'movie'
                ? 'primary_release_date.desc'
                : 'first_air_date.desc'
              : 'popularity.desc';
        if (genre) params.with_genres = String(genre[input.type]);
        if (input.year)
          params[input.type === 'movie' ? 'primary_release_year' : 'first_air_date_year'] =
            input.year;
        params['vote_count.gte'] = input.sort === 'rating' ? '200' : '20';
        if (input.minimum) params['vote_average.gte'] = String(input.minimum);
        params[input.type === 'movie' ? 'primary_release_date.lte' : 'first_air_date.lte'] =
          new Date().toISOString().slice(0, 10);
      }
      const data = await request(
        input.source === 'because'
          ? `${input.type}/${seedId}/recommendations`
          : `discover/${input.type}`,
        params
      );
      if (!Array.isArray(data.results) || data.results.length > 100) throw upstream();
      const items: DiscoveryItem[] = data.results.flatMap((value) => {
        const base = match(value, input.type);
        const item = record(value);
        if (!base || item.adult === true) return [];
        return [
          {
            ...base,
            backdropPath: path(item.backdrop_path),
            rating:
              typeof item.vote_average === 'number' &&
              item.vote_average > 0 &&
              item.vote_average <= 10
                ? item.vote_average
                : null,
            votes:
              Number.isSafeInteger(item.vote_count) && Number(item.vote_count) >= 0
                ? Number(item.vote_count)
                : 0,
            genres: discoveryGenres
              .filter(
                (g) => Array.isArray(item.genre_ids) && item.genre_ids.includes(g[input.type])
              )
              .map((g) => g.name),
            source: 'tmdb' as const
          }
        ];
      });
      return {
        items,
        page: int(data.page, 1, 500),
        totalPages: Math.min(int(data.total_pages, 0, 1000000), 500),
        source: input.source
      };
    },
    async search(params: URLSearchParams): Promise<SearchPage> {
      const query = searchQuery(params.get('q') ?? '');
      const type = params.get('type') ?? 'all';
      const page = params.get('page') ?? '1';
      if (
        query.length < 2 ||
        query.length > 200 ||
        /[\u0000-\u001f\u007f]/.test(query) ||
        !['all', 'movie', 'tv'].includes(type) ||
        !/^\d+$/.test(page) ||
        +page < 1 ||
        +page > 500
      )
        throw new ApiError(
          400,
          'invalid_input',
          'Enter 2–200 characters and choose a valid search page'
        );
      if (/^tt\d{7,10}$/i.test(query)) {
        const data = await request(`find/${query.toLowerCase()}`, { external_source: 'imdb_id' });
        const movies = Array.isArray(data.movie_results) ? data.movie_results : [];
        const shows = Array.isArray(data.tv_results) ? data.tv_results : [];
        return {
          items: [
            ...(type !== 'tv' ? movies.map((v) => match(v, 'movie')) : []),
            ...(type !== 'movie' ? shows.map((v) => match(v, 'tv')) : [])
          ].filter((v): v is SearchMatch => !!v),
          page: 1,
          totalPages: 1
        };
      }
      const data = await request(`search/${type === 'all' ? 'multi' : type}`, {
        query,
        page,
        include_adult: 'false'
      });
      if (!Array.isArray(data.results) || data.results.length > 100) throw upstream();
      return {
        items: data.results
          .map((v) => match(v, type === 'all' ? undefined : (type as 'movie' | 'tv')))
          .filter((v): v is SearchMatch => !!v),
        page: int(data.page, 1, 500),
        totalPages: Math.min(int(data.total_pages, 0, 1000000), 500)
      };
    },
    async details(mediaType: 'movie' | 'tv', id: number) {
      providerInput(mediaType, id);
      const data = await request(`${mediaType}/${id}`, { append_to_response: 'external_ids' });
      const base = match(data, mediaType);
      if (!base || base.id !== id) throw upstream();
      const rawSeasons = mediaType === 'tv' ? data.seasons : [];
      if (!Array.isArray(rawSeasons) || rawSeasons.length > 1000) throw upstream();
      const seasons = rawSeasons.map((v) => {
        const s = record(v);
        const number = int(s.season_number, 0, 999);
        return {
          number,
          name: text(s.name, 300) || (number ? `Season ${number}` : 'Specials'),
          expectedEpisodes: int(s.episode_count, 0, 5000)
        };
      });
      if (new Set(seasons.map((s) => s.number)).size !== seasons.length) throw upstream();
      const genres = Array.isArray(data.genres)
        ? data.genres
            .map((v) => text(record(v).name, 100))
            .filter(Boolean)
            .slice(0, 40)
        : [];
      const runtime =
        mediaType === 'movie'
          ? data.runtime
          : Array.isArray(data.episode_run_time)
            ? data.episode_run_time[0]
            : null;
      const imdbId =
        data.external_ids && typeof data.external_ids === 'object'
          ? (data.external_ids as RecordValue).imdb_id
          : data.imdb_id;
      return {
        ...base,
        suggestedCategory: (genres.includes('Animation') && data.original_language === 'ja'
          ? mediaType === 'tv'
            ? 'anime'
            : 'anime-movie'
          : mediaType === 'tv'
            ? 'show'
            : 'movie') as 'movie' | 'show' | 'anime' | 'anime-movie',
        seasons,
        genres,
        backdropPath: path(data.backdrop_path),
        runtimeMinutes:
          Number.isInteger(runtime) && (runtime as number) > 0 && (runtime as number) <= 1440
            ? (runtime as number)
            : null,
        communityScore:
          typeof data.vote_average === 'number' && data.vote_average > 0 && data.vote_average <= 10
            ? data.vote_average
            : null,
        imdbId: typeof imdbId === 'string' && /^tt\d{7,10}$/.test(imdbId) ? imdbId : null
      };
    },
    async connection() {
      await request('configuration');
      return { connected: true as const };
    },
    async season(id: number, number: number) {
      providerInput('tv', id);
      if (!Number.isInteger(number) || number < 0 || number > 999)
        throw new ApiError(400, 'invalid_input', 'Choose a valid season');
      const data = await request(`tv/${id}/season/${number}`);
      if (
        data.season_number !== number ||
        !Array.isArray(data.episodes) ||
        data.episodes.length > 5000
      )
        throw upstream();
      const result = data.episodes.map((v) => {
        const e = record(v);
        if (e.season_number !== number) throw upstream();
        return {
          number: int(e.episode_number, 1, 5000),
          tmdbId: int(e.id, 1, 9999999999),
          name: text(e.name, 300),
          overview: text(e.overview, 20000),
          airedOn: date(e.air_date),
          stillPath: path(e.still_path),
          communityScore:
            typeof e.vote_average === 'number' &&
            e.vote_average > 0 &&
            e.vote_average <= 10 &&
            Number(e.vote_count) > 0
              ? e.vote_average
              : null
        };
      });
      if (new Set(result.map((e) => e.number)).size !== result.length) throw upstream();
      return result;
    }
  };
}
export type TmdbClient = ReturnType<typeof createTmdb>;
