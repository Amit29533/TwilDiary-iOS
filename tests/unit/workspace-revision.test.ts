import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sql } from 'drizzle-orm';
import type { D1Database } from '@cloudflare/workers-types';
import { d1Fixture } from '../helpers/d1.ts';
import { connectFixture, fakeTrakt, traktEnv } from '../helpers/trakt.ts';
import {
  bumpWorkspaceRevision,
  changesDiary,
  readWorkspaceRevision
} from '../../src/lib/server/workspace-revision.ts';
import { workspaceChanges } from '../../src/lib/server/workspace.ts';
import { emptyTrash } from '../../src/lib/server/collection-management.ts';
import { startSync, buildSyncStep, applySyncChange } from '../../src/lib/server/trakt-sync.ts';
import { titles, watchEvents, seasons, fileLocations, scannerDevices } from '../../src/lib/server/db/schema.ts';
import { GET as changesRoute } from '../../src/routes/api/workspace/changes/+server.ts';
import worker from '../../workers/trakt-incoming/index.ts';

test('the migration seeds one valid revision and a bump replaces it', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const first = (await readWorkspaceRevision(f.db)).revision;
  assert.match(first, /^[a-f0-9]{32}$/);
  assert.equal((await readWorkspaceRevision(f.db)).revision, first, 'reading never changes it');
  await bumpWorkspaceRevision(f.binding);
  const second = (await readWorkspaceRevision(f.db)).revision;
  assert.match(second, /^[a-f0-9]{32}$/);
  assert.notEqual(second, first);
  assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM workspace_revision').get()!.n, 1);
  assert.throws(() => f.sqlite.exec("INSERT INTO workspace_revision(id,token) VALUES(2,'x')"));
});

test('only API write requests count as diary changes', () => {
  for (const method of ['POST', 'PATCH', 'PUT', 'DELETE'])
    assert.equal(changesDiary(method, '/api/titles/x'), true, method);
  for (const method of ['GET', 'HEAD', 'OPTIONS'])
    assert.equal(changesDiary(method, '/api/workspace'), false, method);
  assert.equal(changesDiary('POST', '/preview/library'), false);
  assert.equal(
    changesDiary('PUT', '/api/settings/apis/TMDB_ACCESS_TOKEN'),
    false,
    'keys are not diary data'
  );
  assert.equal(changesDiary('POST', '/api/files/jellyfin'), true, 'file locations are');
});

test('a failed bump never fails the write it follows', async () => {
  const broken = {
    prepare() {
      throw new Error('D1 unavailable');
    }
  } as unknown as D1Database;
  await bumpWorkspaceRevision(broken, async () => {});
  await bumpWorkspaceRevision(undefined);
});

test('a bump that fails once is retried, so other devices still see the change', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const first = (await readWorkspaceRevision(f.db)).revision;
  let calls = 0;
  const flaky = {
    prepare(sql: string) {
      if (++calls === 1) throw new Error('D1 hiccup');
      return f.binding.prepare(sql);
    }
  } as unknown as D1Database;
  await bumpWorkspaceRevision(flaky, async () => {});
  assert.equal(calls, 2);
  assert.notEqual((await readWorkspaceRevision(f.db)).revision, first);
});

test('a missing or malformed revision is reported, not treated as unchanged', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  f.sqlite.exec("UPDATE workspace_revision SET token='not-a-token'");
  await assert.rejects(readWorkspaceRevision(f.db), /freshness check is unavailable/);
  f.sqlite.exec('DELETE FROM workspace_revision');
  await assert.rejects(readWorkspaceRevision(f.db), /freshness check is unavailable/);
});

test('an idle minute of the incoming Trakt worker leaves the revision alone', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  const before = (await readWorkspaceRevision(f.db)).revision;
  await worker.scheduled({} as never, { ...traktEnv, DB: f.binding });
  assert.equal((await readWorkspaceRevision(f.db)).revision, before);
});

test('readWorkspaceRevision with ?since= returns changedTitleIds for delta sync and workspaceChanges returns single-request delta payload', async (t) => {
  const f = d1Fixture();
  t.after(f.close);

  const since = new Date(Date.now() - 60_000).toISOString();
  const changedAt = new Date().toISOString();
  await f.db.insert(titles).values({
    id: 'delta-movie',
    name: 'Delta Movie',
    sortName: 'delta movie',
    kind: 'movie',
    category: 'movie',
    year: 2026,
    overview: '',
    genres: [],
    status: 'watching',
    favorite: false,
    queued: false,
    notes: '',
    version: 1,
    createdAt: changedAt,
    updatedAt: changedAt
  });

  const rev = await readWorkspaceRevision(f.db, new URLSearchParams({ since }));
  assert.deepEqual(rev.changedTitleIds, ['delta-movie']);

  const delta = await workspaceChanges(
    f.db,
    new URLSearchParams({ since }),
    readWorkspaceRevision
  );
  assert.equal(delta.fullRefreshRequired, false);
  assert.deepEqual(delta.ids, ['delta-movie']);
  assert.equal(delta.titles.length, 1);
  assert.equal(delta.titles[0]!.id, 'delta-movie');

  // Matching known token short-circuits immediately with empty changedTitleIds
  const matchingKnown = await readWorkspaceRevision(
    f.db,
    new URLSearchParams({ since, known: rev.revision })
  );
  assert.deepEqual(matchingKnown.changedTitleIds, []);

  // Changes across watch_events, seasons, and file_locations are all detected
  await f.db.insert(titles).values([
    {
      id: 't-watch',
      name: 'Watch Title',
      sortName: 'watch title',
      kind: 'movie',
      category: 'movie',
      status: 'watching',
      createdAt: '2020-01-01T00:00:00Z',
      updatedAt: '2020-01-01T00:00:00Z'
    },
    {
      id: 't-season',
      name: 'Season Title',
      sortName: 'season title',
      kind: 'series',
      category: 'show',
      status: 'watching',
      createdAt: '2020-01-01T00:00:00Z',
      updatedAt: '2020-01-01T00:00:00Z'
    },
    {
      id: 't-loc',
      name: 'Location Title',
      sortName: 'location title',
      kind: 'movie',
      category: 'movie',
      status: 'watching',
      createdAt: '2020-01-01T00:00:00Z',
      updatedAt: '2020-01-01T00:00:00Z'
    }
  ]);
  await f.db.insert(watchEvents).values({
    id: 'ev-1',
    operationId: 'op-1',
    titleId: 't-watch',
    episodeId: null,
    watchedAt: changedAt,
    recordedAt: changedAt,
    origin: 'manual',
    version: 1
  });
  await f.db.insert(seasons).values({
    id: 's-1',
    titleId: 't-season',
    number: 1,
    name: 'Season 1',
    expectedEpisodes: 10,
    metadataLoadedAt: changedAt,
    metadataVersion: 2
  });
  await f.db.insert(scannerDevices).values({
    id: 'dev-1',
    name: 'PC',
    credentialHash: 'hash',
    createdAt: '2020-01-01T00:00:00Z'
  });
  await f.db.insert(fileLocations).values({
    id: 'loc-1',
    titleId: 't-loc',
    deviceId: 'dev-1',
    volumeId: 'vol-1',
    driveLetter: 'D:',
    root: 'D:\\Media',
    relativePath: 'Movie',
    fileCount: 1,
    evidence: 'present',
    checkedAt: changedAt
  });

  const multiRev = await readWorkspaceRevision(f.db, new URLSearchParams({ since }));
  assert.deepEqual(multiRev.changedTitleIds, ['delta-movie', 't-loc', 't-season', 't-watch']);

  // Invalid or expired (>7d) since omits changedTitleIds and requires full refresh
  const expiredSince = new Date(Date.now() - 8 * 86400_000).toISOString();
  const expiredRev = await readWorkspaceRevision(f.db, new URLSearchParams({ since: expiredSince }));
  assert.equal(expiredRev.changedTitleIds, undefined);
  const fullReq = await workspaceChanges(
    f.db,
    new URLSearchParams({ since: expiredSince }),
    readWorkspaceRevision
  );
  assert.equal(fullReq.fullRefreshRequired, true);

  // Structural purge via emptyTrash / manageTitles(purge) records `purge_at` in trakt_sync_journal,
  // forces full refresh for older `since`, survives a subsequent Trakt sync completion, and
  // resumes normal delta sync for `since > purge_at`.
  await f.db
    .update(titles)
    .set({ deletedAt: new Date().toISOString() })
    .where(sql`id='t-loc'`);
  await emptyTrash(f.db);
  const afterDelete = await readWorkspaceRevision(f.db, new URLSearchParams({ since }));
  assert.equal(afterDelete.changedTitleIds, undefined);
  const fullChangesAfterPurge = await workspaceChanges(
    f.db,
    new URLSearchParams({ since }),
    readWorkspaceRevision
  );
  assert.equal(fullChangesAfterPurge.fullRefreshRequired, true);

  // Even after a Trakt sync run completes and trims trakt_sync_journal, `purge_at` is preserved
  await connectFixture(f);
  const fake = fakeTrakt();
  const { id: runId } = await startSync(f.db, traktEnv, 'round', fake.transport);
  for (let i = 0; i < 30; i++) {
    const step = await buildSyncStep(f.db, traktEnv, runId, fake.transport);
    if (step.run?.state !== 'building') break;
  }
  while (true) {
    const res = await applySyncChange(
      f.db,
      traktEnv,
      runId,
      undefined,
      'apply',
      fake.transport,
      fake.transport
    );
    if (Number((res.counts as Record<string, number>).safe ?? 0) === 0) {
      await applySyncChange(
        f.db,
        traktEnv,
        runId,
        undefined,
        'apply',
        fake.transport,
        fake.transport
      );
      break;
    }
  }
  const stillRequiresFullAfterTrakt = await readWorkspaceRevision(
    f.db,
    new URLSearchParams({ since })
  );
  assert.equal(stillRequiresFullAfterTrakt.changedTitleIds, undefined);

  const futureCursor = await readWorkspaceRevision(f.db, new URLSearchParams({ since: new Date(Date.now() + 60_000).toISOString() }));
  assert.equal(futureCursor.changedTitleIds, undefined, 'A future client clock must force a full refresh');
  const afterPurgeRefreshSince = new Date().toISOString();
  const postRefreshRev = await readWorkspaceRevision(
    f.db,
    new URLSearchParams({ since: afterPurgeRefreshSince })
  );
  assert.deepEqual(postRefreshRev.changedTitleIds, []);

  // Route handler check (requires owner authentication, returns delta JSON when authorized)
  const unauthReply = await changesRoute({
    locals: {},
    url: new URL('https://diary.test/api/workspace/changes?since=' + encodeURIComponent(since)),
    request: new Request('https://diary.test/api/workspace/changes'),
    cookies: { get: () => undefined, delete: () => {} }
  } as never);
  assert.equal(unauthReply.status, 401);
});
