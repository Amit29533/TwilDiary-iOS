import type { D1Database } from '@cloudflare/workers-types';
import { database } from './db/index.ts';
import { databaseQuotaFailure } from './database-failure.ts';

export class ApiError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
export interface ApiContext {
  locals: { owner?: { subject: string; email: string }; bindings?: ServerBindings };
  platform?: { env: ServerBindings } | undefined;
}
export interface ServerBindings {
  DB?: D1Database;
  LOCAL_DIARY?: string;
  LOCAL_LAN_HOST?: string;
  LOCAL_LAN_ENABLED?: string;
  TMDB_ACCESS_TOKEN?: string;
  ACCESS_TEAM_DOMAIN?: string;
  ACCESS_AUDIENCE?: string;
  ACCESS_OWNER_EMAIL?: string;
  TRAKT_CLIENT_ID?: string;
  TRAKT_TOKEN_KEY?: string;
  TRAKT_REDIRECT_URI?: string;
  TRAKT_PERSONAL_ACCESS_TOKEN?: string;
}
export const bindings = (context: ApiContext): ServerBindings =>
  context.locals.bindings ?? context.platform?.env ?? {};
export function privateJson(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'private, no-store',
      'X-Content-Type-Options': 'nosniff'
    }
  });
}
export async function api(
  context: ApiContext,
  action: (db: ReturnType<typeof database>) => Promise<unknown>,
  status = 200
) {
  return ownerApi(
    context,
    async () => {
      const binding = bindings(context).DB;
      if (!binding)
        throw new ApiError(503, 'setup_required', 'The private diary database is not configured');
      return action(database(binding));
    },
    status
  );
}
/** Metadata reads require the owner too, but do not need a database connection. */
export async function ownerApi(context: ApiContext, action: () => Promise<unknown>, status = 200) {
  try {
    if (!context.locals.owner)
      throw new ApiError(401, 'unauthorized', 'Sign in through Cloudflare Access');
    return privateJson(await action(), status);
  } catch (error) {
    if (error instanceof ApiError) {
      const response = privateJson(
        { error: { code: error.code, message: error.message } },
        error.status
      );
      // Preserve a provider's cooldown through our own HTTP boundary. The
      // native bulk worker must not guess a shorter delay from the status alone.
      const retry = 'retryAfter' in error ? error.retryAfter : undefined;
      if (typeof retry === 'number' && Number.isFinite(retry) && retry > 0)
        response.headers.set('Retry-After', String(Math.min(86_400, Math.ceil(retry))));
      return response;
    }
    const quota = databaseQuotaFailure(error);
    if (quota) {
      const { retryAfter, ...detail } = quota;
      const response = privateJson({ error: detail }, 503);
      response.headers.set('Retry-After', String(retryAfter));
      return response;
    }
    // Never log request bodies or SQL parameters: only the error class and message.
    console.error('api_unhandled', {
      name: error instanceof Error ? error.name : typeof error,
      message: error instanceof Error ? error.message.slice(0, 300) : undefined
    });
    return privateJson(
      {
        error: {
          code: 'request_failed',
          message: 'The change could not be completed. Please try again.'
        }
      },
      500
    );
  }
}
export async function readJson(request: Request): Promise<unknown> {
  if (
    request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json'
  )
    throw new ApiError(415, 'json_required', 'Send changes as application/json');
  const limit = 131072;
  if (Number(request.headers.get('content-length')) > limit)
    throw new ApiError(413, 'too_large', 'Keep this request within 128 KB');
  const reader = request.body?.getReader();
  if (!reader) throw new ApiError(400, 'invalid_json', 'A JSON object is required');
  let size = 0;
  const parts: Uint8Array[] = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new ApiError(413, 'too_large', 'Keep this request within 128 KB');
      }
      parts.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, 'invalid_json', 'A valid JSON object is required');
  } finally {
    reader.releaseLock();
  }
}
