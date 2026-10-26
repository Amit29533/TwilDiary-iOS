/** Disposable local workerd/D1 only. Never opens hosted D1 or reads credentials. */
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { database } from '../../src/lib/server/db/index.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import { readWorkspaceRevision } from '../../src/lib/server/workspace-revision.ts';
import {
  startSync,
  buildSyncStep,
  applySyncChange,
  syncStatus
} from '../../src/lib/server/trakt-sync.ts';
import { configureIncoming, tickIncoming } from '../../src/lib/server/trakt-incoming.ts';
import { connectFixture, fakeTrakt, fakeTmdb, traktEnv } from '../../tests/helpers/trakt.ts';
import { createTmdb } from '../../src/lib/server/tmdb.ts';

const mf = new Miniflare(convertV4MiniflareOptions({
  workers: [{ name: 'stage1-local',
  modules: true,
  script: 'export default {fetch(){return new Response("local benchmark")}}',
  compatibilityDate: '2026-10-21',
  d1Databases: ['DB'] }]
}));
try {
  const raw = await mf.getD1Database('DB');
  const totals: Record<string, { queries: number; read: number; written: number }> = {};
  const statements: { phase: string; sql: string; read: number; written: number }[] = [];
  let phase = 'setup';
  const record = (sql: string, result: any) => {
    const value = (totals[phase] ??= { queries: 0, read: 0, written: 0 });
    assert.equal(typeof result.meta.rows_read, 'number');
    value.queries++;
    value.read += result.meta.rows_read;
    value.written += result.meta.rows_written;
    statements.push({ phase, sql, read: result.meta.rows_read, written: result.meta.rows_written });
    return result;
  };
  const originals = new WeakMap<object, any>();
  const binding: any = {
    prepare(sql: string) {
      const wrap = (base: any): any => {
        const value = {
          bind(...args: any[]) {
            return wrap(base.bind(...args));
          },
          async all() {
            return record(sql, await base.all());
          },
          async run() {
            return record(sql, await base.run());
          },
          async first(column?: string) {
            const r = record(sql, await base.all()).results[0];
            return column ? (r?.[column] ?? null) : (r ?? null);
          },
          async raw() {
            return record(sql, await base.all()).results.map((row: any) => Object.values(row));
          }
        };
        originals.set(value, base);
        return value;
      };
      return wrap(raw.prepare(sql));
    },
    async batch(values: any[]) {
      const results = await raw.batch(values.map((value) => originals.get(value)));
      results.forEach((result) => record('BATCH statement', result));
      return results;
    }
  };
  for (const file of readdirSync('drizzle')
    .filter((f) => f.endsWith('.sql'))
    .sort())
    for (const sql of readFileSync('drizzle/' + file, 'utf8')
      .split('--> statement-breakpoint')
      .filter((s) => s.trim()))
      await raw.prepare(sql).run();
  const db = database(binding);
  const bulk = async (sql: string, rows: unknown[]) => {
    for (let i = 0; i < rows.length; i += 100)
      await raw
        .prepare(sql)
        .bind(JSON.stringify(rows.slice(i, i + 100)))
        .run();
  };
  const titleIDs = Array.from({ length: 400 }, (_, i) => 'series-' + String(i).padStart(4, '0'));
  await bulk(
    `INSERT INTO titles(id,name,sort_name,kind,category,status,created_at,updated_at)
    SELECT value,value,value,'series','anime','watching','2026-01-01','2026-01-01' FROM json_each(?)`,
    titleIDs
  );
  await bulk(
    `INSERT INTO seasons(id,title_id,number,name,expected_episodes,metadata_loaded_at,metadata_version)
    SELECT value||'-s1',value,1,'Season 1',16,'2026-10-26',2 FROM json_each(?)`,
    titleIDs
  );
  const eps = titleIDs.flatMap((title, i) =>
    Array.from({ length: 16 }, (_, n) => ({
      id: title + '-e' + (n + 1),
      title,
      season: title + '-s1',
      n: n + 1
    }))
  );
  await bulk(
    `INSERT INTO episodes(id,title_id,season_id,number,name) SELECT json_extract(value,'$.id'),json_extract(value,'$.title'),json_extract(value,'$.season'),json_extract(value,'$.n'),'Episode' FROM json_each(?)`,
    eps
  );
  await bulk(
    `INSERT INTO provider_identities(id,title_id,provider,kind,external_id) SELECT value,value,'tmdb','series',CAST(1000+CAST(substr(value,8) AS INTEGER) AS TEXT) FROM json_each(?)`,
    titleIDs
  );
  await bulk(
    `INSERT INTO watch_events(id,operation_id,title_id,episode_id,watched_at,recorded_at,origin)
    SELECT 'old-'||json_extract(value,'$.id'),'old-'||json_extract(value,'$.id'),json_extract(value,'$.title'),json_extract(value,'$.id'),'2026-01-01T12:00:00Z','2026-01-01T12:00:00Z','manual' FROM json_each(?)`,
    eps.slice(0, 2000)
  );
  await connectFixture({ db } as any);
  const fake = fakeTrakt();
  let providerReads = 0;
  const transport: typeof fetch = (input, init) => {
    if (!init?.method || init.method === 'GET') providerReads++;
    return fake.transport(input, init);
  };
  const snapshot = async () => {
    for (const section of ['titles', 'episodes', 'events', 'locations']) {
      let after: string | null = null;
      do {
        const page = await workspacePage(
          db,
          new URLSearchParams({ section, ...(after ? { after } : {}) })
        );
        after = page.next;
      } while (after);
    }
  };
  phase = 'fullSnapshot';
  await snapshot();
  phase = 'unchangedChecks100';
  for (let i = 0; i < 100; i++) await readWorkspaceRevision(db);
  phase = 'incomingDisabled';
  await tickIncoming(binding, traktEnv, { transport });
  phase = 'configureIncoming';
  await configureIncoming(db, traktEnv, true);
  phase = 'incomingDueUnchanged';
  await tickIncoming(binding, traktEnv, { transport, tmdb: createTmdb('fixture', fakeTmdb) });
  phase = 'incomingNotDue';
  await tickIncoming(binding, traktEnv, { transport });
  // Real reviewed merge functions, synthetic provider, 2,000 missing distinct episode plays.
  fake.state.history = eps
    .slice(2000, 4000)
    .map((e, i) => ({
      id: 100000 + i,
      type: 'episode',
      watched_at: '2026-10-25T12:00:00Z',
      show: { title: e.title, ids: { tmdb: 1000 + titleIDs.indexOf(e.title) } },
      episode: { season: 1, number: e.n, ids: { trakt: 1000000 + i } }
    }));
  phase = 'buildReview2000';
  const { id } = await startSync(db, traktEnv, 'round', transport);
  let status = await syncStatus(db, id),
    steps = 0;
  while (status.run?.state === 'building') {
    assert.ok(steps++ < 1000, 'Bound comparison steps');
    status = await buildSyncStep(db, traktEnv, id, transport);
  }
  assert.equal(status.run?.state, 'review');
  phase = 'incomingPaused';
  await tickIncoming(binding, traktEnv, { transport });
  // Only ready incoming additions; do not export the synthetic old local history.
  const incoming = await raw
    .prepare(
      "SELECT id FROM trakt_sync_changes WHERE run_id=? AND kind='history' AND direction='pull' AND review=0 AND state='pending' ORDER BY id"
    )
    .bind(id)
    .all<{ id: string }>();
  assert.equal(incoming.results.length, 2000);
  phase = 'applyFirst';
  await applySyncChange(db, traktEnv, id, incoming.results[0].id, 'apply', fakeTmdb, transport);
  phase = 'applyRemaining1999';
  for (const change of incoming.results.slice(1))
    await applySyncChange(db, traktEnv, id, change.id, 'apply', fakeTmdb, transport);
  phase = 'snapshotAfterBulk';
  await snapshot();
  const count = await raw
    .prepare('SELECT count(*) n FROM watch_events WHERE revoked_at IS NULL')
    .first<number>('n');
  assert.equal(count, 4000);
  assert.equal(fake.state.posts.length, 0, 'An incoming-only benchmark must never send to Trakt');
  const projection = {
    // One 2k initial import + comparison, 30 changed full reads, 100 unchanged
    // opens, and a deliberately conservative 1,440 due unchanged Cron checks.
    read:
      totals.buildReview2000.read +
      totals.applyFirst.read +
      totals.applyRemaining1999.read +
      30 * totals.snapshotAfterBulk.read +
      totals.unchangedChecks100.read +
      1440 * totals.incomingDueUnchanged.read,
    written:
      totals.buildReview2000.written +
      totals.applyFirst.written +
      totals.applyRemaining1999.written +
      1440 * totals.incomingDueUnchanged.written
  };
  const result = {
    scope: 'Disposable local workerd D1 metadata; not hosted analytics or Free CPU certification',
    dataset: { titles: 400, episodes: 6400, existingWatches: 2000, importedWatches: 2000 },
    totals,
    providerReads,
    projectedWorkload: projection,
    limits: { read: 5000000, written: 100000 },
    expensive: statements
      .filter((s) => s.phase !== 'setup')
      .sort((a, b) => b.read - a.read)
      .slice(0, 15)
  };
  mkdirSync('ios/docs/benchmarks', { recursive: true });
  writeFileSync('ios/docs/benchmarks/stage1-local-d1.json', JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
  assert.ok(
    projection.read < 2500000 && projection.written < 50000,
    'Keep at least 50% headroom in this defined local workload'
  );
} finally {
  await mf.dispose();
}

