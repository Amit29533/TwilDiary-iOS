import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError } from '#lib/server/api.ts';
export const GET: RequestHandler = (event) =>
  api(event, async (db) => {
    const after = event.url.searchParams.get('after') ?? '';
    if (after.length > 128 || /[\u0000-\u001f]/.test(after))
      throw new ApiError(400, 'invalid_input', 'Invalid file page');
    const result = await db.$client
      .prepare(
        `SELECT f.id,f.title_id AS titleId,t.name,f.drive_letter AS driveLetter,f.root,f.relative_path AS relativePath,
    f.file_count AS fileCount,f.evidence,f.checked_at AS checkedAt,d.name AS deviceName FROM file_locations f JOIN titles t ON t.id=f.title_id JOIN scanner_devices d ON d.id=f.device_id
    WHERE t.deleted_at IS NULL AND f.id>? ORDER BY f.id LIMIT 51`
      )
      .bind(after)
      .all();
    const items = result.results.slice(0, 50);
    return { items, next: result.results.length > 50 ? items.at(-1)?.id : null };
  });
