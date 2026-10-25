import { drizzle } from 'drizzle-orm/d1';
import type { D1Database } from '@cloudflare/workers-types';
import * as schema from './schema.ts';

// Pass a request's binding explicitly; never expose database access to a client module.
export function database(binding: D1Database) {
  return drizzle(binding, { schema });
}
