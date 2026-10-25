import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { identity } from '#lib/server/library-input.ts';
import { seasonPage } from '#lib/server/library.ts';
export const GET: RequestHandler = (event) =>
  api(event, (db) =>
    seasonPage(
      db,
      identity(event.params.id),
      Number(event.params.number),
      Number(event.url.searchParams.get('after') ?? '0'),
      Number(event.url.searchParams.get('limit') ?? '50'),
      event.url.searchParams.get('reveal') === '1'
    )
  );
