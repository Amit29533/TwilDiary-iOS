/** D1 wraps quota errors inside query errors. Never expose SQL or bound values. */
export function databaseQuotaFailure(error: unknown, now = new Date()) {
  const visited = new Set<unknown>();
  let cause = error;
  for (let depth = 0; depth < 8 && cause && !visited.has(cause); depth++) {
    visited.add(cause);
    const message = cause instanceof Error ? cause.message : typeof cause === 'string' ? cause : '';
    const match = /Your account has exceeded D1's free tier daily row (read|write) limit/i.exec(
      message
    );
    if (match) {
      const reset = new Date(now);
      reset.setUTCHours(24, 0, 0, 0);
      return {
        code: match[1]!.toLowerCase() === 'read' ? 'database_read_limit' : 'database_write_limit',
        message:
          'The diary database has reached its daily Cloudflare limit. Your data is safe. Access resumes after midnight UTC.',
        resetAt: reset.toISOString(),
        retryAfter: Math.max(1, Math.ceil((reset.getTime() - now.getTime()) / 1000))
      };
    }
    cause = cause instanceof Error ? cause.cause : undefined;
  }
  return null;
}
