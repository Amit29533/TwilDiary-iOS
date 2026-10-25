import { ApiError } from './api.ts';
import type { Category, WatchStatus } from '../domain/types.ts';
import { searchQuery } from '../metadata.ts';

const categories: Category[] = ['movie', 'show', 'anime', 'anime-movie'];
const statuses: WatchStatus[] = ['planned', 'watching', 'completed', 'dropped'];
const invalid = (message: string): never => {
  throw new ApiError(400, 'invalid_input', message);
};
export function object(value: unknown, keys: readonly string[]): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value))
    return invalid('A JSON object is required');
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((key) => !keys.includes(key)))
    return invalid('This request contains unsupported fields');
  return record;
}
export function identity(value: unknown, label = 'Identity'): string {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/.test(value))
    return invalid(`${label} is invalid`);
  return value;
}
export function version(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1)
    return invalid('A valid expectedVersion is required');
  return value as number;
}
export function name(value: unknown): string {
  if (typeof value !== 'string') return invalid('Enter a title');
  const clean = value.normalize('NFKC').trim();
  if (!clean || clean.length > 300 || /[\u0000-\u001f\u007f]/.test(clean))
    return invalid('Keep titles between 1 and 300 characters');
  return clean;
}
export const sortName = (value: string) => value.normalize('NFKC').toLowerCase();
export function timestamp(value: unknown): string | null {
  if (value === null) return null;
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
  )
    return invalid('Use a watch timestamp or null for an unknown date');
  const date = new Date(value);
  const calendar = new Date(value.slice(0, 10) + 'T00:00:00Z');
  if (
    Number.isNaN(date.getTime()) ||
    Number.isNaN(calendar.getTime()) ||
    calendar.toISOString().slice(0, 10) !== value.slice(0, 10)
  )
    return invalid('Watch date is invalid');
  return date.toISOString();
}
export function createInput(value: unknown) {
  const data = object(value, ['id', 'name', 'category', 'year', 'status', 'score']);
  if (typeof data.id === 'string' && data.id.startsWith('tmdb-'))
    return invalid('Provider identities are reserved for metadata imports');
  if (!categories.includes(data.category as Category))
    return invalid('Choose a supported media category');
  if (
    data.year !== null &&
    data.year !== undefined &&
    (!Number.isInteger(data.year) || (data.year as number) < 1800 || (data.year as number) > 2200)
  )
    return invalid('Choose a valid release year');
  const { patch } = patchInput({
    expectedVersion: 1,
    status: data.status === undefined ? 'planned' : data.status,
    score: data.score ?? null
  });
  return {
    id: identity(data.id),
    name: name(data.name),
    category: data.category as Category,
    status: patch.status!,
    score: patch.score!,
    year: (data.year as number | null | undefined) ?? null
  };
}
export function patchInput(value: unknown) {
  const data = object(value, [
    'expectedVersion',
    'name',
    'status',
    'favorite',
    'queued',
    'score',
    'notes'
  ]);
  const expectedVersion = version(data.expectedVersion);
  const patch: {
    name?: string;
    status?: WatchStatus;
    favorite?: boolean;
    queued?: boolean;
    score?: number | null;
    notes?: string;
  } = {};
  if ('name' in data) patch.name = name(data.name);
  if ('status' in data) {
    if (!statuses.includes(data.status as WatchStatus))
      return invalid('Choose a supported watch status');
    patch.status = data.status as WatchStatus;
  }
  if ('favorite' in data) {
    if (typeof data.favorite !== 'boolean') return invalid('Favorite must be true or false');
    patch.favorite = data.favorite;
  }
  if ('queued' in data) {
    if (typeof data.queued !== 'boolean') return invalid('Queue must be true or false');
    patch.queued = data.queued;
  }
  if ('score' in data) {
    if (
      data.score !== null &&
      (typeof data.score !== 'number' ||
        !Number.isFinite(data.score) ||
        data.score < 1 ||
        data.score > 10)
    )
      return invalid('Choose a score from 1 to 10');
    patch.score = data.score as number | null;
  }
  if ('notes' in data) {
    if (typeof data.notes !== 'string' || data.notes.length > 20000)
      return invalid('Keep notes within 20,000 characters');
    patch.notes = data.notes;
  }
  if (!Object.keys(patch).length) return invalid('Choose a field to update');
  return { expectedVersion, patch };
}
export function watchInput(value: unknown) {
  const data = object(value, ['operationId', 'episodeId', 'watchedAt', 'rewatch']);
  if (data.episodeId !== null && typeof data.episodeId !== 'string')
    return invalid('Choose an episode, or null for a movie');
  if (data.rewatch !== undefined && typeof data.rewatch !== 'boolean')
    return invalid('Rewatch must be true or false');
  return {
    operationId: identity(data.operationId, 'Operation identity'),
    episodeId: data.episodeId === null ? null : identity(data.episodeId, 'Episode identity'),
    watchedAt: timestamp(data.watchedAt),
    rewatch: data.rewatch === true
  };
}
export function libraryInput(params: URLSearchParams) {
  const query = searchQuery(params.get('q') ?? '').toLowerCase();
  if (query.length > 200) return invalid('Keep search within 200 characters');
  const status = params.get('status') ?? 'all';
  const category = params.get('category') ?? 'all';
  if (status !== 'all' && !statuses.includes(status as WatchStatus))
    return invalid('Invalid status filter');
  if (category !== 'all' && !categories.includes(category as Category))
    return invalid('Invalid category filter');
  const rawLimit = params.get('limit') ?? '24';
  if (!/^\d+$/.test(rawLimit) || +rawLimit < 1 || +rawLimit > 60)
    return invalid('Page size must be between 1 and 60');
  const trash = params.get('trash') === '1';
  const disk = params.get('disk') ?? 'all';
  let diskIdentity: { deviceId: string; volumeId: string } | null = null;
  const driveLetter = /^drive:[A-Z]:$/.test(disk) ? disk.slice(6) : null;
  if (disk !== 'all' && disk !== 'unmapped' && disk !== 'downloads' && !driveLetter) {
    try {
      if (disk.length > 1024) throw new Error();
      const pair: unknown = JSON.parse(disk);
      if (
        !Array.isArray(pair) ||
        pair.length !== 2 ||
        pair.some(
          (value) =>
            typeof value !== 'string' ||
            !value.length ||
            value.length > 256 ||
            /[\u0000-\u001f\u007f]/.test(value)
        )
      )
        throw new Error();
      diskIdentity = { deviceId: pair[0], volumeId: pair[1] };
    } catch {
      return invalid('Choose a valid disk');
    }
  }
  const favorite = params.get('favorite') ?? '0';
  const pc = params.get('pc') ?? '0';
  const queue = params.get('queue') ?? '0';
  if (!['0', '1'].includes(queue)) return invalid('Invalid Queue filter');
  const queued = queue === '1' || disk === 'downloads';
  if (!['0', '1'].includes(pc)) return invalid('Invalid PC filter');
  if (!['0', '1'].includes(favorite)) return invalid('Invalid favorites filter');
  const genre = params.get('genre') ?? '';
  if (genre.length > 100 || /[\u0000-\u001f\u007f]/.test(genre))
    return invalid('Choose a valid genre');
  const scope = JSON.stringify([query, status, category, trash, disk, favorite, genre, pc, queued]);
  const rawCursor = params.get('cursor');
  let after: { sortName: string; id: string } | null = null;
  if (rawCursor) {
    try {
      if (rawCursor.length > 4096) throw new Error();
      const decoded = JSON.parse(
        new TextDecoder('utf-8', { fatal: true }).decode(
          Uint8Array.from(atob(rawCursor.replace(/-/g, '+').replace(/_/g, '/')), (c) =>
            c.charCodeAt(0)
          )
        )
      );
      if (
        decoded.scope !== scope ||
        typeof decoded.sortName !== 'string' ||
        decoded.sortName.length > 600
      )
        throw new Error();
      after = { sortName: decoded.sortName, id: identity(decoded.id) };
    } catch {
      return invalid('This page cursor is invalid for the current filters');
    }
  }
  return {
    query,
    status: status as WatchStatus | 'all',
    category: category as Category | 'all',
    limit: +rawLimit,
    trash,
    disk,
    diskIdentity,
    driveLetter,
    favorite: favorite === '1',
    pc: pc === '1',
    queued,
    genre,
    scope,
    after
  };
}
export function cursorFor(sortName: string, id: string, scope: string) {
  const bytes = new TextEncoder().encode(JSON.stringify({ sortName, id, scope }));
  return btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(''))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
