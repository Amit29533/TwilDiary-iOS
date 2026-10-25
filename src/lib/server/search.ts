import { ApiError } from './api.ts';
import { listLibrary, searchIdentities } from './library.ts';
import type { database } from './db/index.ts';
import type { TmdbClient } from './tmdb.ts';
import { searchQuery } from '../metadata.ts';
import type { DiarySearchPage } from '../search.ts';

export async function searchDiary(
  db: ReturnType<typeof database>,
  params: URLSearchParams,
  metadata: TmdbClient
): Promise<DiarySearchPage> {
  const query = searchQuery(params.get('q') ?? '');
  const rawPage = params.get('page') ?? '1';
  if (
    query.length < 2 ||
    query.length > 200 ||
    /[\u0000-\u001f\u007f]/.test(query) ||
    !/^\d+$/.test(rawPage) ||
    +rawPage < 1 ||
    +rawPage > 500
  )
    throw new ApiError(400, 'invalid_input', 'Enter a title or IMDb ID (2–200 characters)');
  const libraryParams = new URLSearchParams({ q: query, limit: '20' });
  if (params.has('cursor')) libraryParams.set('cursor', params.get('cursor')!);
  // A metadata outage must not hide local matches. Owner/session/DB failures still fail closed.
  const [local, remote] = await Promise.all([
    params.get('scope') === 'online'
      ? Promise.resolve({ items: [], nextCursor: null })
      : listLibrary(db, libraryParams),
    metadata.search(new URLSearchParams({ q: query, page: rawPage })).then(
      (value) => ({ value, error: '' }),
      (error: unknown) => ({
        value: null,
        error:
          error instanceof ApiError ? error.message : 'Online search is temporarily unavailable.'
      })
    )
  ]);
  const identities = await searchIdentities(db, remote.value?.items ?? []);
  const library = [...local.items];
  const seen = new Set(library.map((title) => title.id));
  const online: DiarySearchPage['online'] = [];
  for (const item of remote.value?.items ?? []) {
    const existing = identities.find(
      (identity) =>
        identity.externalId === String(item.id) &&
        identity.kind === (item.mediaType === 'tv' ? 'series' : 'movie')
    );
    if (existing && !existing.title.deletedAt) {
      if (!seen.has(existing.title.id)) {
        library.push(existing.title);
        seen.add(existing.title.id);
      }
    } else online.push({ ...item, ...(existing ? { trashId: existing.title.id } : {}) });
  }
  return {
    library,
    online,
    nextCursor: local.nextCursor,
    page: remote.value?.page ?? 1,
    totalPages: remote.value?.totalPages ?? 0,
    onlineError: remote.error
  };
}
