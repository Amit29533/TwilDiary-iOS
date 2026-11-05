/**
 * Trakt-first plan, phase 4c (ios/docs/TRAKT-CLIENT-PLAN.md): which service holds the diary.
 *
 * `DIARY_RECORD` (a Worker variable) is `server` until the switch-over, then `trakt`, `simkl` or
 * `mdblist`. Once it names a service:
 * - the server diary's own record (watches and ratings) is kept read-only, as a fallback copy,
 *   for 30 days from `DIARY_RECORD_SINCE`; extras (notes, tags, Queue, favourites, files, Trash,
 *   backups, imports) are still written;
 * - the Review sync with Trakt is retired (the app writes to the service itself);
 * - the web app shows a notice instead of the diary; the API stays for the app.
 * Setting `DIARY_RECORD` back to `server` (or removing it) undoes all three.
 */
export type DiaryRecord = 'server' | 'trakt' | 'simkl' | 'mdblist';

type RecordEnv = { DIARY_RECORD?: string; DIARY_RECORD_SINCE?: string } | undefined;

export function diaryRecord(env: RecordEnv): DiaryRecord {
  const value = env?.DIARY_RECORD?.trim().toLowerCase();
  return value === 'trakt' || value === 'simkl' || value === 'mdblist' ? value : 'server';
}

const DAY = 86_400_000;

/** What the app reads: the record, when it moved, and until when the server copy stays frozen. */
export function recordStatus(env: RecordEnv) {
  const record = diaryRecord(env);
  const since = record === 'server' ? null : validDate(env?.DIARY_RECORD_SINCE);
  return {
    record,
    since,
    readOnlyUntil: since ? new Date(Date.parse(since) + 30 * DAY).toISOString() : null
  };
}

function validDate(value: string | undefined) {
  if (!value || value.length > 40) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
}

const NAMES: Record<DiaryRecord, string> = {
  server: 'your server',
  trakt: 'Trakt',
  simkl: 'Simkl',
  mdblist: 'MDBList'
};

/**
 * Why a request is refused once a service holds the diary, or null when it may go ahead.
 * `body` is the parsed JSON body of a title PATCH (only its keys are looked at).
 */
export function recordRefusal(
  record: DiaryRecord,
  method: string,
  path: string,
  body?: unknown
): { status: number; code: string; message: string } | null {
  if (record === 'server' || ['GET', 'HEAD', 'OPTIONS'].includes(method)) return null;
  const name = NAMES[record];
  // The Review sync and the incoming watches: the app writes to the service itself now.
  if (path === '/api/trakt/sync' || path.startsWith('/api/trakt/sync/') || path === '/api/trakt/incoming')
    return {
      status: 410,
      code: 'review_sync_retired',
      message: `${name} holds your diary now, so the Review sync is retired. Edits go to ${name} from the app.`
    };
  const frozen = {
    status: 423,
    code: 'diary_record_moved',
    message: `${name} holds your diary now. Your server’s watches and ratings are kept read-only as a backup; turn on “Show my diary from ${name}” in the app to edit.`
  };
  // Watches: logging one, changing or removing one, season progress (which logs or removes
  // watches), the old pull from a service into the server, the one-off legacy migration, and
  // importing an archive or CSV (which brings in watches and ratings too; the app restores a
  // backup into the service instead).
  if (
    /^\/api\/titles\/[^/]+\/watches$/.test(path) ||
    path.startsWith('/api/watch-events/') ||
    path === '/api/progress/status' ||
    /^\/api\/providers\/[^/]+\/sync$/.test(path) ||
    path === '/api/workspace/migrate' ||
    path === '/api/workspace/import'
  )
    return frozen;
  // Ratings on a title. Status stays writable: the server keeps what the service can't
  // (a dropped movie on Trakt or MDBList, for instance).
  if (method === 'PATCH' && /^\/api\/titles\/[^/]+$/.test(path)) {
    if (body && typeof body === 'object' && !Array.isArray(body) && 'score' in body) return frozen;
  }
  return null;
}

/** Where the retired web app points you. */
export function retiredWebPage(record: DiaryRecord) {
  const name = NAMES[record];
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TwilDiary</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#15111d;color:#f3f0f7;font:16px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:30rem;padding:2rem}h1{font-size:1.5rem;margin:0 0 .5rem}p{color:#b9b0c8}</style></head>
<body><main><h1>TwilDiary lives in the app now</h1>
<p>Your diary is kept on ${name} and in the TwilDiary iPhone app. This web version is retired.</p>
<p>Your server keeps a read-only copy of your old diary, and your backups stay in the app under Profile → Backups.</p>
</main></body></html>`;
}
