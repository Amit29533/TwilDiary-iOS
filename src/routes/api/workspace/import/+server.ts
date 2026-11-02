import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError } from '#lib/server/api.ts';
import {
  importDiaryArchive,
  parseExternalCsvToArchive
} from '#lib/server/workspace-migration.ts';

const MAX_ARCHIVE_BYTES = 8 * 1024 * 1024;

export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const contentType = event.request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase();
    if (contentType !== 'application/json') {
      throw new ApiError(415, 'json_required', 'Send backup archive as application/json');
    }
    const contentLength = Number(event.request.headers.get('content-length'));
    if (contentLength > MAX_ARCHIVE_BYTES) {
      throw new ApiError(413, 'too_large', 'Keep backup archive within 8 MB');
    }
    const text = await event.request.text();
    if (text.length > MAX_ARCHIVE_BYTES) {
      throw new ApiError(413, 'too_large', 'Keep backup archive within 8 MB');
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new ApiError(400, 'invalid_json', 'Choose a valid TwilDiary JSON backup file.');
    }
    if (
      parsed &&
      typeof parsed === 'object' &&
      !Array.isArray(parsed) &&
      typeof (parsed as { csv?: unknown }).csv === 'string'
    ) {
      const archive = parseExternalCsvToArchive((parsed as { csv: string }).csv);
      return importDiaryArchive(db, archive);
    }
    return importDiaryArchive(db, parsed);
  });
