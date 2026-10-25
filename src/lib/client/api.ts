export class ClientError extends Error {
  status: number;
  code: string;
  constructor(message: string, status: number, code: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
// Session-only cache invalidation shared by every real-diary write surface.
let confirmedMutation = 0;
export const mutationRevision = () => confirmedMutation;
/** Same-origin only. HTML from an expired Access session is never mistaken for diary JSON. */
export async function requestJson<T>(
  path: string,
  options: RequestInit = {},
  transport: typeof fetch = fetch
): Promise<T> {
  if (!path.startsWith('/api/') || path.startsWith('//')) throw new Error('Use a diary API path');
  const response = await transport(path, {
    ...options,
    credentials: 'same-origin',
    redirect: 'error',
    headers: {
      Accept: 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers
    }
  });
  if (!response.headers.get('content-type')?.includes('application/json'))
    throw new ClientError(
      'Your private session is unavailable. Open the diary again to sign in.',
      response.status,
      'session_unavailable'
    );
  const data = await response.json();
  if (!response.ok)
    throw new ClientError(
      data.error?.message ?? 'The request could not be completed.',
      response.status,
      data.error?.code ?? 'request_failed'
    );
  if (!['GET', 'HEAD'].includes((options.method ?? 'GET').toUpperCase())) confirmedMutation++;
  return data as T;
}
export const errorMessage = (error: unknown) =>
  error instanceof Error && error.name === 'AbortError'
    ? ''
    : error instanceof ClientError
      ? error.message
      : 'Could not connect. Your changes have not been confirmed; please try again.';
