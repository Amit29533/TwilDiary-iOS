import type { database } from './db/index.ts';
import type { TmdbClient } from './tmdb.ts';
import { searchIdentities } from './library.ts';
import { ApiError } from './api.ts';
import { providerInput } from './tmdb.ts';

/** Browsing never imports a title or changes watch history. */
export async function browseMetadata(
  db: ReturnType<typeof database>,
  params: URLSearchParams,
  metadata: TmdbClient
) {
  const { mediaType, id } = providerInput(params.get('type'), params.get('id'));
  const details = await metadata.details(mediaType, id);
  const [existing] = await searchIdentities(db, [details]);
  return {
    details,
    libraryTitle: existing ? { id: existing.title.id, trashed: !!existing.title.deletedAt } : null
  };
}

export async function browseSeason(params: URLSearchParams, metadata: TmdbClient) {
  const { mediaType, id } = providerInput(params.get('type'), params.get('id'));
  const raw = params.get('season') ?? '';
  if (mediaType !== 'tv' || !/^\d{1,3}$/.test(raw))
    throw new ApiError(400, 'invalid_input', 'Choose a valid show season');
  const reveal = params.get('reveal') === '1';
  const items = await metadata.season(id, Number(raw));
  return {
    items: items.map((item) => ({
      ...item,
      name: reveal ? item.name : '',
      overview: reveal ? item.overview : '',
      stillPath: reveal ? item.stillPath : null
    }))
  };
}
