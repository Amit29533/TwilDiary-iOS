import { performance } from 'node:perf_hooks';
import { cpus, platform, release, totalmem } from 'node:os';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { homePage, historyPage, diaryStats } from '../../src/lib/server/dashboard.ts';
import {
  workspacePage,
  workspaceTitles,
  workspaceChanges
} from '../../src/lib/server/workspace.ts';
import { readWorkspaceRevision } from '../../src/lib/server/workspace-revision.ts';
import { getTitle, patchTitle } from '../../src/lib/server/library.ts';
import {
  importDiaryArchive,
  parseExternalCsvToArchive
} from '../../src/lib/server/workspace-migration.ts';
import { readProviderVault, writeProviderVault } from '../../src/lib/server/provider-vault.ts';
import { signDiarySessionToken, verifyDiarySessionToken } from '../../src/lib/server/access.ts';

const output = resolve(process.argv[2] ?? '../outputs/regression-2026-11-03/benchmarks.json');
const results: Record<string, unknown>[] = [];
const round = (value: number) => Math.round(value * 1000) / 1000;
async function measure(
  name: string,
  f: ReturnType<typeof d1Fixture>,
  body: () => Promise<unknown> | unknown,
  count = 30
) {
  for (let i = 0; i < 3; i++) await body();
  f.resetMetrics();
  const times: number[] = [],
    cpu = process.cpuUsage(),
    memory = process.memoryUsage();
  let value: unknown;
  for (let i = 0; i < count; i++) {
    const start = performance.now();
    value = await body();
    times.push(performance.now() - start);
  }
  const used = process.cpuUsage(cpu),
    after = process.memoryUsage();
  const sorted = [...times].sort((a, b) => a - b),
    percentile = (p: number) => round(sorted[Math.ceil(p * count) - 1]!);
  const result = {
    name,
    iterations: count,
    warmups: 3,
    milliseconds: {
      min: round(sorted[0]!),
      p50: percentile(0.5),
      p95: percentile(0.95),
      p99: percentile(0.99),
      max: round(sorted.at(-1)!)
    },
    cpuMilliseconds: round((used.user + used.system) / 1000),
    heapDeltaBytes: after.heapUsed - memory.heapUsed,
    rssBytes: after.rss,
    serializedResultBytes: Buffer.byteLength(JSON.stringify(value) ?? ''),
    database: {
      ...f.metrics,
      statementsPerIteration: f.metrics.statements / count,
      roundTripsPerIteration: f.metrics.roundTrips / count
    },
    rawMilliseconds: times.map(round)
  };
  results.push(result);
  console.log(
    name,
    JSON.stringify(result.milliseconds),
    `${result.database.statementsPerIteration} SQL statements/op`
  );
}
function seed(f: ReturnType<typeof d1Fixture>, count: number) {
  const title = f.sqlite.prepare(
    'INSERT INTO titles (id,name,sort_name,kind,category,status,runtime_minutes,score,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)'
  );
  const season = f.sqlite.prepare(
    'INSERT INTO seasons (id,title_id,number,name,expected_episodes) VALUES (?,?,1,?,24)'
  );
  const episode = f.sqlite.prepare(
    'INSERT INTO episodes (id,title_id,season_id,number,name,aired_on) VALUES (?,?,?,?,?,?)'
  );
  const event = f.sqlite.prepare(
    'INSERT INTO watch_events (id,operation_id,title_id,episode_id,watched_at,recorded_at,origin) VALUES (?,?,?,?,?,?,?)'
  );
  const stamp = '2026-10-01T12:00:00.000Z';
  f.sqlite.exec('BEGIN');
  for (let i = 0; i < count; i++) {
    const id = 'seed-' + i,
      series = i % 3 === 0;
    title.run(
      id,
      'Synthetic ' + i,
      'synthetic ' + String(i).padStart(5, '0'),
      series ? 'series' : 'movie',
      series ? 'show' : 'movie',
      i % 10 === 0 ? 'planned' : series ? 'watching' : 'completed',
      series ? 24 : 100,
      8,
      stamp,
      stamp
    );
    if (series) {
      season.run(id + '-s1', id, 'Season 1');
      for (let ep = 1; ep <= 24; ep++)
        episode.run(`${id}-e${ep}`, id, id + '-s1', ep, 'Episode ' + ep, '2026-10-01');
    }
    for (let play = 0; play < 20; play++) {
      const eventId = `${id}-v${play}`,
        at = new Date(Date.parse(stamp) + play * 86400_000).toISOString();
      event.run(eventId, eventId, id, series ? `${id}-e${play + 1}` : null, at, at, 'manual');
    }
  }
  f.sqlite.exec('COMMIT');
}

for (const size of [300, 3000]) {
  const f = d1Fixture();
  try {
    seed(f, size);
    const prefix = `${size} titles / ${size * 8} episodes / ${size * 20} watches`;
    await measure(
      prefix + ': Home',
      f,
      () => homePage(f.db, new URLSearchParams({ day: '2026-11-03' })),
      20
    );
    await measure(prefix + ': History first page', f, () =>
      historyPage(f.db, new URLSearchParams({ limit: '30' }))
    );
    await measure(prefix + ': Statistics', f, () => diaryStats(f.db));
    await measure(prefix + ': Workspace titles page', f, () =>
      workspacePage(f.db, new URLSearchParams({ section: 'titles' }))
    );
    await measure(prefix + ': One title refresh', f, () =>
      workspaceTitles(f.db, new URLSearchParams({ ids: 'seed-0' }))
    );
    const revision = await readWorkspaceRevision(f.db);
    await measure(prefix + ': Unchanged delta', f, () =>
      workspaceChanges(
        f.db,
        new URLSearchParams({
          known: revision.revision,
          since: new Date(Date.now() - 60_000).toISOString()
        }),
        readWorkspaceRevision
      )
    );
    await historyPage(f.db, new URLSearchParams({ limit: '30' }));
    const actual = f.lastStatement()!;
    results.push({
      name: prefix + ': Actual history plan',
      query: actual.query,
      plan: f.sqlite.prepare('EXPLAIN QUERY PLAN ' + actual.query).all(...actual.values)
    });
    results.push({
      name: prefix + ': Query plans',
      plans: {
        history: f.sqlite
          .prepare(
            'EXPLAIN QUERY PLAN SELECT id FROM watch_events WHERE revoked_at IS NULL ORDER BY coalesce(watched_at,recorded_at) DESC,id DESC LIMIT 30'
          )
          .all(),
        progress: f.sqlite
          .prepare(
            "EXPLAIN QUERY PLAN SELECT episode_id FROM watch_events WHERE title_id='seed-0' AND revoked_at IS NULL"
          )
          .all()
      }
    });
  } finally {
    f.close();
  }
}
{
  const f = d1Fixture();
  try {
    seed(f, 30);
    const env = { DIARY_AUTH_SECRET: 'synthetic-benchmark-signing-key-2026' };
    const token = (
      await signDiarySessionToken(
        { subject: 'fixture', email: 'fixture@example.test', method: 'passcode' },
        env
      )
    ).token;
    await measure('Signed session verify', f, () => verifyDiarySessionToken(token, env), 500);
    await measure(
      'Vault encrypt + CAS write + decrypt',
      f,
      async () => {
        const previous = await readProviderVault(f.db, env);
        await writeProviderVault(f.db, env, {
          expectedRevision: previous.revision,
          changes: { simkl: { accessToken: 'synthetic-fixture-token' } }
        });
        const saved = await readProviderVault(f.db, env);
        assert.equal(saved.settings?.simkl?.accessToken, 'synthetic-fixture-token');
        return { synced: saved.synced };
      },
      100
    );
    const races = [];
    for (let round = 0; round < 50; round++) {
      const title = await getTitle(f.db, 'seed-0');
      const attempts = await Promise.allSettled(
        Array.from({ length: 8 }, (_, i) =>
          patchTitle(f.db, 'seed-0', {
            expectedVersion: title.version,
            notes: `round ${round} writer ${i}`
          })
        )
      );
      const accepted = attempts.filter((item) => item.status === 'fulfilled').length;
      assert.equal(accepted, 1);
      races.push({ accepted, rejected: attempts.length - accepted });
    }
    results.push({
      name: 'Optimistic-edit race torture',
      rounds: 50,
      attemptedWrites: 400,
      acceptedWrites: 50,
      conflicts: 350,
      lostUpdates: 0,
      raw: races
    });
    const csv =
      'Name,Year,Rating\n' +
      Array.from({ length: 5000 }, (_, i) => `Synthetic ${i},2020,8`).join('\n');
    await measure(
      'CSV maximum 5000 rows parse',
      f,
      () => {
        const archive = parseExternalCsvToArchive(csv);
        assert.equal(archive.titles.length, 5000);
        return { titles: archive.titles.length, events: archive.events.length };
      },
      10
    );
    const archive = {
      schemaVersion: 1,
      titles: Array.from({ length: 300 }, (_, i) => ({
        id: 'archive-' + i,
        name: 'Archive fixture ' + i,
        category: 'movie',
        status: 'planned'
      })),
      episodes: [],
      events: [],
      locations: [],
      skippedEpisodeIds: []
    };
    await measure(
      'Archive repeat import 300 titles',
      f,
      () => importDiaryArchive(f.db, archive),
      10
    );
  } finally {
    f.close();
  }
}
const report = {
  generatedAt: new Date().toISOString(),
  source: {
    commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    dirty: !!execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim()
  },
  environment: {
    node: process.version,
    sqlite: process.versions.sqlite,
    platform: platform(),
    release: release(),
    architecture: process.arch,
    cpu: cpus()[0]?.model,
    logicalCPUs: cpus().length,
    totalMemoryBytes: totalmem()
  },
  scope:
    'In-process real Drizzle/SQLite with seeded synthetic data; no Cloudflare network latency, real-account writes, or UI frame-rate inference.',
  results
};
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify(report, null, 2));
console.log('Report:', output);
