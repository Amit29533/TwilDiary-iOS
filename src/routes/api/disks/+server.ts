import type { RequestHandler } from '@sveltejs/kit';
import { api } from '#lib/server/api.ts';
import { listDisks } from '#lib/server/disks.ts';
export const GET: RequestHandler = (event) => api(event, listDisks);
