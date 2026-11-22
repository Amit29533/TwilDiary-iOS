import type { RequestHandler } from '@sveltejs/kit';
import { api, ApiError, readJson } from '#lib/server/api.ts';
import { importDiaryArchive, parseExternalCsvToArchive } from '#lib/server/workspace-migration.ts';

const MAX_ARCHIVE_BYTES = 8 * 1024 * 1024;

export const POST: RequestHandler = (event) =>
  api(event, async (db) => {
    const parsed = await readJson(event.request, {
      maxBytes: MAX_ARCHIVE_BYTES,
      sizeLabel: '8 MB'
    });
    if (
      parsed &&
      typeof parsed === 'object' &&
      !Array.isArray(parsed) &&
      typeof (parsed as { csv?: unknown }).csv === 'string'
    ) {
      const zone = (parsed as { timeZone?: unknown }).timeZone;
      if (zone !== undefined && (typeof zone !== 'string' || zone.length > 100))
        throw new ApiError(400, 'invalid_timezone', 'Choose a valid CSV time zone.');
      const archive = parseExternalCsvToArchive(
        (parsed as { csv: string }).csv,
        zone as string | undefined
      );
      return importDiaryArchive(db, archive);
    }
    return importDiaryArchive(db, parsed);
  });
