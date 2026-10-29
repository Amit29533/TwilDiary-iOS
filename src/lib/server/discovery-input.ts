import { ApiError } from './api.ts';
import { discoveryNetworks, genreAvailable, type DiscoveryQuery } from '../discovery.ts';
export function discoveryInput(params: URLSearchParams): DiscoveryQuery {
  const source = params.get('source') ?? 'tmdb';
  const type = params.get('type') ?? 'movie';
  const genre = params.get('genre') ?? '';
  const year = params.get('year') ?? '';
  const sort = params.get('sort') ?? 'popular';
  const minimum = params.get('minimum') ?? '0';
  const page = params.get('page') ?? '1';
  const seed = params.get('seed') ?? '';
  const network = params.get('network') ?? '';
  if (
    !['tmdb', 'trakt', 'because'].includes(source) ||
    !['movie', 'tv'].includes(type) ||
    !['popular', 'rating', 'newest', 'trending'].includes(sort) ||
    (network &&
      (type !== 'tv' ||
        source !== 'tmdb' ||
        !discoveryNetworks.some((n) => String(n.id) === network))) ||
    (genre && !genreAvailable(genre, type as 'movie' | 'tv')) ||
    (year && (!/^\d{4}$/.test(year) || +year < 1880 || +year > 2200)) ||
    !/^(?:[0-9](?:\.\d)?|10(?:\.0)?)$/.test(minimum) ||
    !/^\d{1,3}$/.test(page) ||
    +page < 1 ||
    +page > 500 ||
    (seed && !/^[a-zA-Z0-9-]{1,100}$/.test(seed))
  )
    throw new ApiError(400, 'invalid_discovery', 'Choose valid discovery filters');
  return {
    source,
    type,
    genre,
    year,
    sort,
    minimum: +minimum,
    page: +page,
    seed,
    ...(network ? { network: +network } : {})
  } as DiscoveryQuery;
}
