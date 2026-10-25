import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import type { D1Database } from '@cloudflare/workers-types';
import { database } from '../../src/lib/server/db/index.ts';

// Run the real Drizzle D1 driver against SQLite. Network/Worker behavior is tested separately.
export function d1Fixture() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec('PRAGMA foreign_keys=ON');
  for (const file of readdirSync(new URL('../../drizzle/', import.meta.url))
    .filter((file) => file.endsWith('.sql'))
    .sort())
    sqlite.exec(readFileSync(new URL('../../drizzle/' + file, import.meta.url), 'utf8'));
  function statement(query: string, values: SQLInputValue[] = []) {
    return {
      bind(...params: SQLInputValue[]) {
        return statement(query, params);
      },
      execute() {
        const prepared = sqlite.prepare(query);
        const results = prepared.all(...values);
        return {
          success: true,
          results,
          meta: { changes: sqlite.prepare('SELECT changes() AS n').get()!.n }
        };
      },
      async all() {
        return this.execute();
      },
      async run() {
        return this.execute();
      },
      async raw() {
        const prepared = sqlite.prepare(query);
        prepared.setReturnArrays(true);
        return prepared.all(...values);
      },
      async first(column?: string) {
        const row = sqlite.prepare(query).get(...values);
        return column ? (row?.[column] ?? null) : (row ?? null);
      }
    };
  }
  const binding = {
    prepare: statement,
    async batch(statements: ReturnType<typeof statement>[]) {
      sqlite.exec('BEGIN');
      try {
        const results = statements.map((statement) => statement.execute());
        sqlite.exec('COMMIT');
        return results;
      } catch (error) {
        sqlite.exec('ROLLBACK');
        throw error;
      }
    }
  } as unknown as D1Database;
  return { sqlite, binding, db: database(binding), close: () => sqlite.close() };
}
