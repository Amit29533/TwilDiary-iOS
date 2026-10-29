import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { D1Database } from '@cloudflare/workers-types';
import { d1Fixture } from '../helpers/d1.ts';
import { traktEnv } from '../helpers/trakt.ts';
import {
  bumpWorkspaceRevision,
  changesDiary,
  readWorkspaceRevision
} from '../../src/lib/server/workspace-revision.ts';
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
  await bumpWorkspaceRevision(broken);
  await bumpWorkspaceRevision(undefined);
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
