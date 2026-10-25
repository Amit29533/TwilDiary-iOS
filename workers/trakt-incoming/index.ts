import type { D1Database, ScheduledController } from '@cloudflare/workers-types';
import { tickIncoming } from '../../src/lib/server/trakt-incoming.ts';
import type { ServerBindings } from '../../src/lib/server/api.ts';

type Env = ServerBindings & { DB: D1Database };
export default {
  // There is no public sync URL, authentication bypass, or service token.
  fetch() {
    return new Response('Not found', { status: 404 });
  },
  async scheduled(_controller: ScheduledController, env: Env) {
    try {
      const result = await tickIncoming(env.DB, env);
      // Only enumerated state/error codes. Never log raw D1/network exceptions.
      console.info(JSON.stringify(result));
    } catch {
      console.error('Incoming watch check unavailable; retained work will retry.');
      throw new Error('Incoming watch check failed');
    }
  }
};
