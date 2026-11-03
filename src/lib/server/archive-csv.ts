import { createHash } from 'node:crypto';
import { ApiError } from './api.ts';
import { validDate, validInstant } from '../domain/history.ts';

const invalid = (message: string): never => {
  throw new ApiError(400, 'invalid_csv', message);
};
const digest = (value: string) => createHash('sha256').update(value).digest('hex').slice(0, 32);

/** RFC 4180 rows, including escaped quotes, CRLF and quoted multiline cells. */
export function csvRows(text: string): string[][] {
  if (Buffer.byteLength(text, 'utf8') > 8 * 1024 * 1024) invalid('Keep the CSV within 8 MB.');
  const rows: string[][] = [];
  let row: string[] = [],
    cell = '',
    quoted = false,
    closed = false;
  function pushCell() {
    if (row.length >= 128) invalid('CSV files can contain up to 128 columns.');
    row.push(cell);
    cell = '';
    closed = false;
  }
  function pushRow() {
    if (!row.some((value) => value.trim())) return;
    if (rows.length >= 5001)
      invalid('Import up to 5,000 CSV rows at a time. No rows were imported.');
    rows.push(row);
  }
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') {
        quoted = false;
        closed = true;
      } else cell += ch;
    } else if (ch === '"') {
      if (closed || cell.trim()) invalid('A CSV quote appears inside an unquoted field.');
      quoted = true;
      cell = '';
    } else if (ch === ',') {
      pushCell();
    } else if (ch === '\r' || ch === '\n') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      pushCell();
      pushRow();
      row = [];
      cell = '';
      closed = false;
    } else {
      if (closed && ch.trim()) invalid('Unexpected text after a quoted CSV field.');
      if (!closed) cell += ch;
    }
    if (cell.length > 20000) invalid('Keep each CSV field within 20,000 characters.');
  }
  if (quoted) invalid('A quoted CSV field is not closed.');
  pushCell();
  pushRow();
  if (rows.length < 2) invalid('The CSV is empty or has no data rows.');
  if (rows.length > 5001) invalid('Import up to 5,000 CSV rows at a time. No rows were imported.');
  return rows;
}

/** One canonical parser for web and native uploads. No invented release years, runtimes or watch dates. */
export function parseExternalCsvToArchive(text: string, timeZone = 'UTC') {
  let dateFormatter: Intl.DateTimeFormat;
  try {
    dateFormatter = new Intl.DateTimeFormat('en-CA', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23'
    });
  } catch {
    return invalid('Choose a valid time zone for date-only CSV entries.');
  }
  function localNoon(day: string): string {
    const target = Date.parse(day + 'T12:00:00Z');
    let instant = target;
    for (let attempt = 0; attempt < 3; attempt++) {
      const parts = Object.fromEntries(
        dateFormatter.formatToParts(new Date(instant)).map((part) => [part.type, part.value])
      );
      const observed = Date.parse(
        `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}Z`
      );
      if (observed === target) return new Date(instant).toISOString();
      instant += target - observed;
    }
    return invalid('A CSV watch date does not exist in the chosen time zone.');
  }
  const rows = csvRows(text.replace(/^\uFEFF/, ''));
  const headers = rows[0]!.map((value) => value.normalize('NFKC').trim().toLowerCase());
  if (new Set(headers).size !== headers.length) invalid('CSV column names must be unique.');
  const column = (...names: string[]) => headers.findIndex((key) => names.includes(key));
  const nameColumn = column('name', 'title', 'series_title', 'series title', 'original title');
  if (nameColumn < 0) invalid('Could not find a Title or Name column.');
  const yearColumn = column('year', 'release year');
  const ratingColumn = column('rating', 'your rating', 'my_score', 'score');
  const typeColumn = column('title type', 'type', 'series_type', 'category');
  const statusColumn = column('status', 'my_status');
  const mal = headers.includes('series_title') || headers.includes('series title');
  const letterboxd =
    headers.includes('letterboxd uri') ||
    (headers.includes('name') && headers.includes('watched date'));
  const watchColumn = column(
    'watched date',
    'my_finish_date',
    'date completed',
    ...(letterboxd ? ['date'] : [])
  );
  const imdbColumn = column('const', 'imdb_id', 'imdb id');
  const tmdbColumn = column('tmdb_id', 'tmdb id');
  const malColumn = column('series_animedb_id', 'anime_id', 'mal_id');
  const uriColumn = column('letterboxd uri');
  const noteColumn = column('notes', 'my_comments', 'comments', 'review');
  const titles = new Map<string, Record<string, unknown>>();
  const events: Record<string, unknown>[] = [];
  const occurrences = new Map<string, number>();
  const now = new Date().toISOString();
  for (let rowIndex = 1; rowIndex < rows.length; rowIndex++) {
    const row = rows[rowIndex]!;
    const value = (index: number) => (index < 0 ? '' : (row[index] ?? '').trim());
    if (row.length !== headers.length)
      invalid(`CSV row ${rowIndex + 1} has a different number of columns.`);
    const name = value(nameColumn);
    if (!name || name.length > 300)
      invalid(`CSV row ${rowIndex + 1} needs a title of 1 to 300 characters.`);
    const yearText = value(yearColumn),
      year = yearText ? Number(yearText) : null;
    if (year !== null && (!Number.isInteger(year) || year < 1800 || year > 2200))
      invalid(`CSV row ${rowIndex + 1} has an invalid release year.`);
    const rawType = value(typeColumn).toLowerCase();
    if (rawType.includes('episode'))
      invalid(`CSV row ${rowIndex + 1} is an episode; import a title-level export instead.`);
    const isMovie =
      rawType.includes('movie') ||
      (!mal &&
        !rawType.includes('tv') &&
        !rawType.includes('series') &&
        !rawType.includes('show') &&
        !rawType.includes('anime'));
    const category =
      mal || rawType.includes('anime')
        ? isMovie
          ? 'anime-movie'
          : 'anime'
        : isMovie
          ? 'movie'
          : 'show';
    const kind = category === 'movie' || category === 'anime-movie' ? 'movie' : 'series';
    const tmdb = value(tmdbColumn),
      imdb = value(imdbColumn),
      malId = value(malColumn),
      uri = value(uriColumn);
    if (tmdb && !/^[1-9]\d{0,9}$/.test(tmdb))
      invalid(`CSV row ${rowIndex + 1} has an invalid TMDB ID.`);
    if (imdb && !/^tt\d{7,10}$/.test(imdb))
      invalid(`CSV row ${rowIndex + 1} has an invalid IMDb ID.`);
    const identity = tmdb
      ? `tmdb:${kind}:${tmdb}`
      : imdb
        ? `imdb:${kind}:${imdb}`
        : malId && /^\d+$/.test(malId)
          ? `mal:${category}:${malId}`
          : uri
            ? `letterboxd:${uri}`
            : `title:${category}:${name.normalize('NFKC')}:${year ?? 'unknown'}`;
    const id = tmdb
      ? `tmdb-${kind === 'series' ? 'tv' : 'movie'}-${tmdb}`
      : imdb
        ? `csv-imdb-${imdb}`
        : `csv-${digest(identity)}`;
    const ratingText = value(ratingColumn);
    let score: number | null = null;
    if (ratingText && ratingText !== '0') {
      const rating = Number(ratingText);
      if (!Number.isFinite(rating) || rating <= 0 || rating > (letterboxd ? 5 : 10))
        invalid(`CSV row ${rowIndex + 1} has an invalid rating.`);
      score = Math.max(1, Math.round(rating * (letterboxd ? 2 : 1) * 10) / 10);
    }
    const dateText = value(watchColumn);
    let watchedAt: string | null = null;
    if (dateText && dateText !== '0000-00-00') {
      if (/^\d{4}-\d{2}-\d{2}$/.test(dateText) && validDate(dateText))
        watchedAt = localNoon(dateText);
      else if (validInstant(dateText)) watchedAt = new Date(dateText).toISOString();
      else invalid(`CSV row ${rowIndex + 1} has an invalid watch date.`);
    }
    const rawStatus = value(statusColumn).toLowerCase().replace(/[_-]/g, ' ');
    const status = ['completed', 'watched', 'finished', '2'].includes(rawStatus)
      ? 'completed'
      : ['dropped', '4'].includes(rawStatus)
        ? 'dropped'
        : ['watching', 'currently watching', 'on hold', '3', '1'].includes(rawStatus)
          ? 'watching'
          : ['planned', 'plan to watch', 'plantowatch', 'watchlist', '6'].includes(rawStatus)
            ? 'planned'
            : watchedAt
              ? 'completed'
              : 'planned';
    const notes = value(noteColumn);
    if (notes.length > 20000)
      invalid(`CSV row ${rowIndex + 1} has a note longer than 20,000 characters.`);
    const existing = titles.get(id);
    if (
      existing &&
      (existing.name !== name || existing.category !== category || existing.year !== year)
    )
      invalid(`CSV row ${rowIndex + 1} conflicts with another row's source identity.`);
    titles.set(id, {
      ...(existing ?? {}),
      id,
      name,
      category,
      year,
      runtimeMinutes: null,
      status,
      score: score ?? existing?.score ?? null,
      personalRating: score ?? existing?.score ?? null,
      tmdbId: tmdb ? Number(tmdb) : null,
      overview: '',
      poster: null,
      backdrop: null,
      genres: [],
      seasons: [],
      notes: notes || existing?.notes || ''
    });
    if (kind === 'movie' && (watchedAt || status === 'completed')) {
      const key = `${id}:${watchedAt ?? 'undated'}`;
      const occurrence = (occurrences.get(key) ?? 0) + 1;
      occurrences.set(key, occurrence);
      const operation = `csv-watch-${digest(`${key}:${occurrence}`)}`;
      events.push({
        id: operation,
        operationId: operation,
        titleId: id,
        episodeId: null,
        watchedAt,
        recordedAt: now,
        revokedAt: null,
        origin: 'import'
      });
    }
  }
  return {
    schemaVersion: 1,
    titles: [...titles.values()],
    episodes: [],
    events,
    locations: [],
    skippedEpisodeIds: []
  };
}
