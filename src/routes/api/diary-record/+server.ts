import { json, type RequestHandler } from '@sveltejs/kit';
import { recordStatus } from '#lib/server/diary-record.ts';

/** Which service holds the diary (phase 4c), so the app shows the diary from it. */
export const GET: RequestHandler = ({ locals }) => {
  if (!locals.owner) return new Response('Sign in to your diary', { status: 401 });
  return json(recordStatus(locals.bindings), { headers: { 'Cache-Control': 'private, no-store' } });
};
