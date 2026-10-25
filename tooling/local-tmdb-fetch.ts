import { request } from 'node:https';
import { resolve4 } from 'node:dns/promises';

const requestAddress = (url: URL, init: RequestInit, address: string): Promise<Response> =>
  new Promise((resolve, reject) => {
    const headers = new Headers(init.headers);
    const req = request(
      url,
      {
        family: 4,
        method: 'GET',
        signal: init.signal ?? undefined,
        lookup: (_host, _options, callback) => callback(null, address, 4),
        headers: {
          Authorization: headers.get('Authorization') ?? '',
          Accept: 'application/json',
          'Accept-Encoding': 'identity'
        }
      },
      (response) => {
        const chunks: Buffer[] = [];
        let size = 0;
        response.on('data', (chunk: Buffer) => {
          size += chunk.byteLength;
          if (size > 2_000_000) {
            req.destroy(new Error('Metadata response too large'));
            return;
          }
          chunks.push(chunk);
        });
        response.on('error', reject);
        response.on('end', () =>
          resolve(
            new Response(Uint8Array.from(Buffer.concat(chunks)), {
              status: response.statusCode ?? 502,
              headers: { 'Content-Type': response.headers['content-type'] ?? 'application/json' }
            })
          )
        );
      }
    );
    req.on('error', reject);
    req.setTimeout(3000, () =>
      req.destroy(Object.assign(new Error('Connection timed out'), { code: 'ETIMEDOUT' }))
    );
    req.end();
  });

/** Node development only. DNS failover keeps the original TLS hostname/certificate verification. */
export function createLocalTmdbFetch(
  addresses: () => Promise<string[]> = () => resolve4('api.themoviedb.org'),
  send: typeof requestAddress = requestAddress
): typeof fetch {
  let cached: { until: number; values: string[] } | undefined;
  let preferred: string | undefined;
  return async (input, init = {}) => {
    const url = new URL(String(input));
    if (
      url.origin !== 'https://api.themoviedb.org' ||
      url.username ||
      url.password ||
      !url.pathname.startsWith('/3/') ||
      (init.method && init.method !== 'GET')
    )
      throw new Error('Use the fixed TMDB read API');
    if (!cached || cached.until < Date.now())
      cached = { values: await addresses(), until: Date.now() + 60000 };
    const candidates = [...cached.values].sort(
      (a, b) => Number(b === preferred) - Number(a === preferred)
    );
    let failure: unknown = new Error('TMDB DNS did not return an address');
    for (const address of candidates.slice(0, 4)) {
      init.signal?.throwIfAborted();
      try {
        const response = await send(url, init, address);
        preferred = address;
        return response;
      } catch (error) {
        failure = error;
        if (
          !['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EHOSTUNREACH', 'ENETUNREACH'].includes(
            (error as NodeJS.ErrnoException).code ?? ''
          )
        )
          throw error;
      }
    }
    throw failure;
  };
}
export const localTmdbFetch = createLocalTmdbFetch();
