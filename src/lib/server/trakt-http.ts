import { ApiError } from './api.ts';
export class TraktError extends ApiError {
  retryAfter: number;
  retryAfterPresent: boolean;
  constructor(
    status: number,
    code: string,
    message: string,
    retryAfter = 0,
    retryAfterPresent = retryAfter > 0
  ) {
    super(status, code, message);
    this.retryAfter = retryAfter;
    this.retryAfterPresent = retryAfterPresent;
  }
}
export async function traktRequest(
  path: string,
  clientId: string,
  token: string | undefined,
  options: {
    method?: 'GET' | 'POST';
    body?: unknown;
    transport?: typeof fetch;
    maxResponseBytes?: number;
  } = {}
) {
  if (
    !/^\/(?:oauth\/token|sync\/[a-z_]+(?:\/[a-z_]+)?|sync\/history\/(?:movies|episodes)\/\d{1,10}|users\/settings|recommendations\/(?:movies|shows)|search\/tmdb\/\d{1,10}|(?:movies|shows)\/\d{1,10}\/(?:ratings|stats|sentiments)|shows\/\d{1,10}\/seasons\/\d{1,3}\/episodes\/\d{1,4})$/.test(
      path.split('?')[0] ?? ''
    )
  )
    throw new ApiError(400, 'invalid_trakt_path', 'Unsupported Trakt operation');
  let response: Response;
  try {
    response = await (options.transport ?? fetch)('https://api.trakt.tv' + path, {
      method: options.method ?? 'GET',
      headers: {
        Accept: 'application/json',
        'User-Agent': 'TwilDiary/2.0.0',
        'Content-Type': 'application/json',
        'trakt-api-key': clientId,
        'trakt-api-version': '2',
        ...(token ? { Authorization: 'Bearer ' + token } : {})
      },
      ...(options.body ? { body: JSON.stringify(options.body) } : {}),
      // Workers supports only manual/follow. Non-2xx (including redirects) is rejected below.
      redirect: 'manual',
      signal: AbortSignal.timeout(10000)
    });
  } catch {
    throw new TraktError(502, 'trakt_unavailable', 'Could not reach Trakt. Please retry.');
  }
  if (response.status === 429) {
    const header = response.headers.get('Retry-After');
    const raw =
      header && /^\d+(?:\.\d+)?$/.test(header.trim())
        ? Number(header)
        : header
          ? (Date.parse(header) - Date.now()) / 1000
          : Number.NaN;
    const present = Number.isFinite(raw) && raw > 0;
    throw new TraktError(
      429,
      'trakt_rate_limited',
      'Trakt is busy. Try again after the cooldown.',
      present ? Math.min(86_400, Math.ceil(raw)) : 60,
      present
    );
  }
  if (response.status === 401)
    throw new TraktError(503, 'trakt_reconnect_required', 'Reconnect your Trakt account.');
  if ([403, 420, 423, 426].includes(response.status))
    throw new TraktError(
      503,
      'trakt_access_limited',
      'Trakt did not allow this operation. Check your account or app limits.'
    );
  if (!response.ok)
    throw new TraktError(
      response.status === 400 ? 400 : 502,
      response.status === 400 ? 'trakt_invalid_grant' : 'trakt_unavailable',
      response.status === 400
        ? 'Trakt could not accept this authorization. Reconnect your account.'
        : 'Trakt could not complete this operation.'
    );
  if (response.status === 204) return { data: null, headers: response.headers };
  const reader = response.body?.getReader();
  if (!reader)
    throw new TraktError(502, 'trakt_incomplete', 'Trakt returned an incomplete response.');
  let size = 0;
  const parts: Uint8Array[] = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > Math.min(2_000_000, options.maxResponseBytes ?? 2_000_000)) {
        await reader.cancel();
        throw new Error();
      }
      parts.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return {
      data: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as unknown,
      headers: response.headers
    };
  } catch {
    throw new TraktError(502, 'trakt_incomplete', 'Trakt returned an incomplete response.');
  } finally {
    reader.releaseLock();
  }
}
