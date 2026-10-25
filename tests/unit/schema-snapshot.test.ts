import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { generateSQLiteDrizzleJson, generateSQLiteMigration } from 'drizzle-kit/api';
import * as schema from '../../src/lib/server/db/schema.ts';

test('the latest migration snapshot matches the schema and cannot regenerate existing tables', async () => {
  const journal = JSON.parse(
    readFileSync(new URL('../../drizzle/meta/_journal.json', import.meta.url), 'utf8')
  );
  const index = String(journal.entries.at(-1).idx).padStart(4, '0');
  const saved = JSON.parse(
    readFileSync(new URL('../../drizzle/meta/' + index + '_snapshot.json', import.meta.url), 'utf8')
  );
  const current = await generateSQLiteDrizzleJson(schema, saved.id);
  assert.deepEqual(
    await generateSQLiteMigration(saved, current),
    [],
    'Generate and commit the schema snapshot with each migration'
  );
});
