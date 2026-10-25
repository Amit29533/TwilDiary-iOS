import { test } from 'node:test';
import assert from 'node:assert/strict';
import { d1Fixture } from '../helpers/d1.ts';
import { sampleDiary } from '../../src/lib/preview/fixtures.ts';
import { importPreviewWorkspace } from '../../src/lib/server/workspace-migration.ts';
import { workspacePage } from '../../src/lib/server/workspace.ts';
import { addManualTitle } from '../../src/lib/server/library.ts';

test('legacy runtime imports obey the same whole-minute bounds as TMDB metadata', async (t) => {
  for (const runtime of [0.5, 2.5, 1441, Number.MAX_SAFE_INTEGER]) {
    const f = d1Fixture();
    t.after(f.close);
    const input = sampleDiary();
    input.titles[0]!.runtimeMinutes = runtime;
    await assert.rejects(() => importPreviewWorkspace(f.db, input), { code: 'invalid_input' });
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM titles').get()!.n, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM workspace_migrations').get()!.n, 0);
  }
});

test('an old malformed runtime cannot make the entire native workspace undecodable', async (t) => {
  const f = d1Fixture();
  t.after(f.close);
  await addManualTitle(f.db, { id: 'runtime-audit', name: 'Runtime boundary', category: 'movie' });
  for (const runtime of [2.5, -1, 1441, Number.MAX_SAFE_INTEGER, 1, 1440, null]) {
    f.sqlite.prepare('UPDATE titles SET runtime_minutes=? WHERE id=?').run(runtime, 'runtime-audit');
    const page = await workspacePage(f.db, new URLSearchParams('section=titles'));
    const title = page.items[0] as unknown as { runtimeMinutes: number | null };
    const expected = runtime === 1 || runtime === 1440 ? runtime : null;
    assert.equal(title.runtimeMinutes, expected);
    assert.equal(
      f.sqlite.prepare('SELECT runtime_minutes FROM titles WHERE id=?').get('runtime-audit')!.runtime_minutes,
      runtime,
      'Reading must not silently rewrite existing diary records'
    );
  }
});
