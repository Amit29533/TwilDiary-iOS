import { ApiError } from './api.ts';
import type { TmdbClient } from './tmdb.ts';

/** Canvas's Lists tab: Trakt's public trending/popular lists, with TMDb posters (Trakt's own
 * images may not be hotlinked). Reads no diary data, so it never touches D1. */
export interface CanvasList {
  id: number;
  name: string;
  user: string;
  itemCount: number;
  likes: number;
  posters: string[];
}
export interface CanvasListItem {
  tmdbId: number;
  mediaType: 'movie' | 'tv';
  name: string;
  year: number | null;
  posterPath: string | null;
  backdropPath: string | null;
}
export interface CanvasListQuery {
  sort: 'trending' | 'popular';
  kind: 'personal' | 'official';
  page: number;
}

/** Eight lists × (1 item request + 4 posters) + 1 stays under Workers' 50 subrequests. */
export const LISTS_PER_PAGE = 8;
export const PREVIEW_POSTERS = 4;
/** One list page: 1 item request + 24 posters. */
export const ITEMS_PER_PAGE = 24;

export function canvasListInput(params: URLSearchParams): CanvasListQuery {
  const sort = params.get('sort') ?? 'trending';
  const kind = params.get('kind') ?? 'personal';
  const page = params.get('page') ?? '1';
  if (
    !['trending', 'popular'].includes(sort) ||
    !['personal', 'official'].includes(kind) ||
    !/^\d{1,2}$/.test(page) ||
    +page < 1 ||
    +page > 50
  )
    throw new ApiError(400, 'invalid_lists', 'Choose valid list filters.');
  return { sort, kind, page: +page } as CanvasListQuery;
}

export function canvasListId(value: string | undefined) {
  if (!value || !/^\d{1,10}$/.test(value) || +value < 1)
    throw new ApiError(400, 'invalid_lists', 'Choose a valid Trakt list.');
  return +value;
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}
function text(value: unknown, max: number) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}
function count(value: unknown) {
  return Number.isSafeInteger(value) && Number(value) >= 0 ? Number(value) : 0;
}

async function traktJson(clientId: string | undefined, path: string, transport: typeof fetch) {
  if (!clientId?.trim())
    throw new ApiError(503, 'trakt_setup_required', 'Trakt is not connected to this diary yet.');
  let response: Response;
  try {
    response = await transport(`https://api.trakt.tv/${path}`, {
      headers: {
        'trakt-api-key': clientId,
        'trakt-api-version': '2',
        'User-Agent': 'TwilDiary/2.0.0',
        Accept: 'application/json'
      },
      signal: AbortSignal.timeout(8000),
      redirect: 'manual'
    });
  } catch {
    throw new ApiError(502, 'trakt_unavailable', 'Could not reach Trakt. Try again shortly.');
  }
  if (response.status === 404)
    throw new ApiError(404, 'list_not_found', 'This list is private or no longer exists.');
  if (response.status === 429)
    throw new ApiError(429, 'trakt_rate_limited', 'Trakt is busy. Wait a moment before retrying.');
  if (!response.ok)
    throw new ApiError(502, 'trakt_unavailable', 'Trakt lists are temporarily unavailable.');
  const body = await response.text();
  if (body.length > 1_000_000)
    throw new ApiError(502, 'trakt_unavailable', 'Trakt returned an unexpected response.');
  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch {
    throw new ApiError(502, 'trakt_unavailable', 'Trakt returned an unexpected response.');
  }
  if (!Array.isArray(data))
    throw new ApiError(502, 'trakt_unavailable', 'Trakt returned an unexpected response.');
  const pages = Number(response.headers.get('X-Pagination-Page-Count'));
  return { data, totalPages: Number.isSafeInteger(pages) && pages > 0 ? Math.min(pages, 50) : 1 };
}

/** Movies and shows on a list, in its own order, with their TMDb IDs. Other entries are skipped. */
function listEntries(data: unknown[]) {
  return data.flatMap((value) => {
    const entry = record(value);
    const mediaType = entry.type === 'movie' ? 'movie' : entry.type === 'show' ? 'tv' : null;
    if (!mediaType) return [];
    const media = record(entry[entry.type as string]);
    const tmdbId = record(media.ids).tmdb;
    if (!Number.isSafeInteger(tmdbId) || Number(tmdbId) < 1) return [];
    return [{ mediaType, tmdbId: Number(tmdbId), name: text(media.title, 300), year: media.year }];
  });
}

async function artwork(tmdb: TmdbClient, entries: ReturnType<typeof listEntries>) {
  const resolved = await Promise.allSettled(
    entries.map((entry) => tmdb.artwork(entry.mediaType as 'movie' | 'tv', entry.tmdbId))
  );
  return entries.map((entry, index): CanvasListItem => {
    const result = resolved[index]!;
    const art = result.status === 'fulfilled' ? result.value : null;
    return {
      tmdbId: entry.tmdbId,
      mediaType: entry.mediaType as 'movie' | 'tv',
      name: art?.name || entry.name,
      year: art?.year ?? (Number.isSafeInteger(entry.year) ? Number(entry.year) : null),
      posterPath: art?.posterPath ?? null,
      backdropPath: art?.backdropPath ?? null
    };
  });
}

export async function canvasLists(
  clientId: string | undefined,
  tmdb: TmdbClient,
  query: CanvasListQuery,
  transport: typeof fetch = fetch
) {
  const { data, totalPages } = await traktJson(
    clientId,
    `lists/${query.sort}/${query.kind}?page=${query.page}&limit=${LISTS_PER_PAGE}`,
    transport
  );
  const lists = data.slice(0, LISTS_PER_PAGE).flatMap((value) => {
    const list = record(record(value).list);
    const id = record(list.ids).trakt;
    const name = text(list.name, 200);
    if (!Number.isSafeInteger(id) || Number(id) < 1 || !name || list.privacy === 'private')
      return [];
    const user = record(list.user);
    return [
      {
        id: Number(id),
        name,
        user: text(user.username, 100) || text(user.name, 100),
        itemCount: count(list.item_count),
        likes: count(list.likes)
      }
    ];
  });
  // A failed preview leaves the card without posters rather than failing the whole page.
  const previews = await Promise.allSettled(
    lists.map(async (list) => {
      const items = await traktJson(
        clientId,
        `lists/${list.id}/items/movie,show?page=1&limit=${PREVIEW_POSTERS}`,
        transport
      );
      const art = await artwork(tmdb, listEntries(items.data).slice(0, PREVIEW_POSTERS));
      return art.flatMap((item) => (item.posterPath ? [item.posterPath] : []));
    })
  );
  return {
    lists: lists.map((list, index): CanvasList => ({
      ...list,
      posters:
        previews[index]!.status === 'fulfilled'
          ? (previews[index] as PromiseFulfilledResult<string[]>).value
          : []
    })),
    page: query.page,
    totalPages
  };
}

export async function canvasListItems(
  clientId: string | undefined,
  tmdb: TmdbClient,
  id: number,
  page: number,
  transport: typeof fetch = fetch
) {
  const { data, totalPages } = await traktJson(
    clientId,
    `lists/${id}/items/movie,show?page=${page}&limit=${ITEMS_PER_PAGE}`,
    transport
  );
  return {
    items: await artwork(tmdb, listEntries(data).slice(0, ITEMS_PER_PAGE)),
    page,
    totalPages
  };
}
