# Native authentication independent of database availability

`GET /api/session` returns `{ "authenticated": true }` after the existing request hook verifies the Cloudflare Access assertion and private diary owner. It does not require or query D1. Unauthenticated requests remain protected by Access; the endpoint does not mint tokens, extend sessions or expose owner details. Its JSON is private and not cacheable.

The native app uses this endpoint for the sign-in browser's landing page and subsequent cookie validation. Diary loading follows successful authentication and secure credential storage. Reading the whole workspace is no longer necessary to prove a session is valid.

The server now recognizes Cloudflare D1 daily read/write limit exceptions through their nested query-error causes. It returns HTTP 503, a numeric `Retry-After`, and this error shape:

```json
{
  "error": {
    "code": "database_read_limit",
    "message": "The diary database has reached its daily Cloudflare limit. Your data is safe. Access resumes after midnight UTC.",
    "resetAt": "2026-10-24T00:00:00.000Z"
  }
}
```

Write limits use `database_write_limit`. Neither SQL nor bound values are exposed. Unrelated internal errors keep the generic private 500 response. This identifies backend availability independently of authentication; clients must not clear valid credentials for a database quota response. The reset timestamp follows [Cloudflare's documented midnight-UTC reset](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/).

The workspace episode spoiler query now supplies the title ID along with episode ID and active-watch state. SQLite uses the existing `watch_title_progress` covering index, avoiding a history scan for every episode. No schema migration or record updates are required.

Validation: 346 unit tests, three built-service-worker tests, Svelte/TypeScript checks and production build passed. New tests cover authenticated session validation with no database binding, unauthenticated denial, nested read/write limits, reset boundaries, private response headers and the real workspace query plan. A local HTTP request to the session endpoint returned authenticated JSON; an unauthenticated hosted request still redirected to Access. The native [recovery report](https://github.com/Amit29533/TwilDiary-iOS/blob/main/docs/SIGN-IN-RECOVERY-2026-10-23.md) tracks the corresponding device build and remaining physical-device verification.
