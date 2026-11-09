import { ApiError } from './api.ts';
import { genreAvailable, type DiscoveryQuery } from '../discovery.ts';
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
  // A tag or company from a title page: any TMDb keyword or company ID.
  const keyword = params.get('keyword') ?? '';
  const company = params.get('company') ?? '';
  // Search Lab filters.
  const keywords = (params.get('keywords') ?? '').split(',').filter(Boolean);
  const keywordMode = params.get('keywordMode') ?? 'any';
  const genres = (params.get('genres') ?? '').split(',').filter(Boolean);
  const certification = params.get('certification') ?? '';
  const yearFrom = params.get('yearFrom') ?? '';
  const yearTo = params.get('yearTo') ?? '';
  const status = params.get('status') ?? '';
  const language = params.get('language') ?? '';
  const year4 = (value: string) => /^\d{4}$/.test(value) && +value >= 1880 && +value <= 2200;
  const id = (value: string) => /^\d{1,10}$/.test(value) && +value > 0;
  if (
    !['tmdb', 'trakt', 'because'].includes(source) ||
    !['movie', 'tv'].includes(type) ||
    !['popular', 'rating', 'newest', 'trending'].includes(sort) ||
    (network && (type !== 'tv' || source !== 'tmdb' || !id(network))) ||
    ((keyword || company) && source !== 'tmdb') ||
    (keyword && !id(keyword)) ||
    (company && !id(company)) ||
    keywords.length > 10 ||
    keywords.some((k) => !id(k)) ||
    !['any', 'all'].includes(keywordMode) ||
    genres.length > 6 ||
    genres.some((g) => !genreAvailable(g, type as 'movie' | 'tv')) ||
    (certification &&
      (type !== 'movie' || !['G', 'PG', 'PG-13', 'R', 'NC-17'].includes(certification))) ||
    (yearFrom && !year4(yearFrom)) ||
    (yearTo && !year4(yearTo)) ||
    (status &&
      (type !== 'tv' || !['returning', 'ended', 'canceled', 'production'].includes(status))) ||
    (language && !/^[a-z]{2}$/.test(language)) ||
    ((keywords.length ||
      genres.length ||
      certification ||
      yearFrom ||
      yearTo ||
      status ||
      language) &&
      source !== 'tmdb') ||
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
    ...(network ? { network: +network } : {}),
    ...(keyword ? { keyword: +keyword } : {}),
    ...(company ? { company: +company } : {}),
    ...(keywords.length ? { keywords: keywords.map(Number), keywordMode } : {}),
    ...(genres.length ? { genres } : {}),
    ...(certification ? { certification } : {}),
    ...(yearFrom ? { yearFrom: +yearFrom } : {}),
    ...(yearTo ? { yearTo: +yearTo } : {}),
    ...(status ? { status } : {}),
    ...(language ? { language } : {})
  } as DiscoveryQuery;
}
