import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { diaryStats } from '#lib/server/dashboard.ts';
export const GET: RequestHandler = (event) => api(event, (db) => diaryStats(db));
