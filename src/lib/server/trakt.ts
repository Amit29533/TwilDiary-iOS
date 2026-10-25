import { ApiError } from './api.ts';
/** Personal recommendations only. No public-feed fallback and no upstream credentials in responses. */
export async function personalTrakt(
  clientId: string | undefined,
  accessToken: string | undefined,
  type: 'movie' | 'tv',
  transport: typeof fetch = fetch,
  limit = 8
): Promise<{ tmdbId: number; rating: number | null; votes: number }[]> {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 24)
    throw new ApiError(400, 'invalid_discovery', 'Choose a recommendation limit from 1 to 24.');
  if (!clientId?.trim() || !accessToken?.trim())
    throw new ApiError(
      503,
      'trakt_connection_required',
      'Connect your personal Trakt account before loading its recommendations.'
    );
  let response: Response;
  try {
    response = await transport(
      `https://api.trakt.tv/recommendations/${type === 'movie' ? 'movies' : 'shows'}?limit=${limit}&extended=full`,
      {
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'trakt-api-key': clientId,
          'trakt-api-version': '2',
          'User-Agent': 'TwilDiary/2.0.0',
          Accept: 'application/json'
        },
        signal: AbortSignal.timeout(8000),
        redirect: 'manual'
      }
    );
  } catch {
    throw new ApiError(502, 'trakt_unavailable', 'Could not reach Trakt. Try again shortly.');
  }
  if (response.status === 401 || response.status === 403)
    throw new ApiError(
      503,
      'trakt_reconnect_required',
      'Your personal Trakt connection needs to be renewed.'
    );
  if (response.status === 429)
    throw new ApiError(429, 'trakt_rate_limited', 'Trakt is busy. Wait a moment before retrying.');
  if (!response.ok)
    throw new ApiError(
      502,
      'trakt_unavailable',
      'Trakt recommendations are temporarily unavailable.'
    );
  const reader = response.body?.getReader();
  if (!reader)
    throw new ApiError(502, 'trakt_unavailable', 'Trakt returned an incomplete response.');
  let text = '';
  const decoder = new TextDecoder();
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 250000) {
        await reader.cancel();
        throw new Error('response too large');
      }
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
    const data: unknown = JSON.parse(text);
    if (!Array.isArray(data) || data.length > 100) throw new Error('invalid response');
    const seen = new Set<number>();
    return data
      .flatMap((item) => {
        const id = item?.ids?.tmdb;
        if (!Number.isSafeInteger(id) || id < 1 || id > 9999999999 || seen.has(id)) return [];
        seen.add(id);
        return [
          {
            tmdbId: id,
            rating:
              typeof item.rating === 'number' && item.rating > 0 && item.rating <= 10
                ? item.rating
                : null,
            votes: Number.isSafeInteger(item.votes) && item.votes >= 0 ? item.votes : 0
          }
        ];
      })
      .slice(0, limit);
  } catch {
    throw new ApiError(502, 'trakt_unavailable', 'Trakt returned incomplete recommendations.');
  } finally {
    reader.releaseLock();
  }
}
