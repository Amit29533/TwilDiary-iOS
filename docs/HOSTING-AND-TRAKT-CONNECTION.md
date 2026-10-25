# Hosting and Trakt connection — 22 October 2026

Canonical application: `/preview`. The original polished UI now uses the real backend throughout. `/diary` contains only a legacy redirect. Startup renders only the centered spinning logo until the workspace is ready, so the header and navigation cannot appear in a partially initialized position.

## Private host

Address: https://twildiary-v2.amit29533.workers.dev/preview/home

Fresh Worker `twildiary-v2`, fresh D1 `twildiary-v2`, migrations through `0008`. The old Netlify project is not used. Worker-level Cloudflare Access protects all traffic, including APIs, assets, OAuth callback and future preview hostnames. Preview deployment URLs remain disabled. The sole allow rule is the owner's exact email; the owner approved the existing Cloudflare identity provider for now. Google OAuth is deferred.

The Worker also validates Access JWT signature, issuer, audience and owner email. Local-development flags are not provisioned in production. Provider credentials and the Trakt encryption key are Worker secrets, never client bundle variables.

Seven local titles, episode records, viewing history and file mappings were copied into the fresh host. The host initialized its six demo entries during sign-in, so the final transfer merged missing records without overwriting hosted records. The local database remains intact. A private local SQL backup is retained under ignored `.local/backups/`. Local and hosted D1 are separate: subsequent local edits do not automatically reach production.

## Trakt

Register the Production Trakt app with this exact callback:

```
https://twildiary-v2.amit29533.workers.dev/api/trakt/callback
```

The Client ID has been saved through the masked PC-only field and provisioned to the Worker. Sign-in uses PKCE with no client secret. Live authorization succeeded as `@amit29533`; encrypted connection state was verified in D1 and the UI displays Connected. Connecting alone does not start sync. A read-only preview was manually started for verification and read 2,200 provider records; comparison is resumable. No proposed changes were applied. More → Trakt requires review before applying conflicts or removals. Queue, notes, locations and marked demo titles are excluded from exports. Trakt ratings are rounded while local decimal ratings remain intact.

During live setup, the first callback could not finish because the provider clients used `redirect: 'error'`. Workerd rejects that mode before sending a request. All three clients (TMDB, Trakt sync/auth, Trakt recommendations) now use `manual` and reject non-success statuses, including redirects, so credentials are never forwarded to a redirected destination. Trakt also rejected requests without an application User-Agent; both Trakt clients now send `TwilDiary/2.0.0`, as recommended in its required headers guide. A new test bundles the actual clients into Workerd, verifies successful requests, checks the app header, and checks redirect rejection without external network calls. The callback exposes only fixed sanitized failure identifiers for actionable error messages, never authorization codes or provider token bodies.

Live Explore verification loaded eight movie and eight show recommendations from the connected personal account and enriched their posters/details through TMDB. TMDB's connection check also succeeds on the hosted Worker.

## Verification

The app passes `npm run verify`: app/worker type checks, unit/database/controller tests, production build, and compiled service-worker tests. Live unauthenticated requests to the app, APIs, manifest and Trakt callback redirect to Access. The owner successfully signed in to the hosted app and authorized Trakt. Token exchange, authenticated history/rating/watchlist reads and personal recommendations were verified live. Applying two-way changes and rotating a real expiring refresh token remain untested against the owner's live account; fixture tests cover those paths without modifying the real account.

The live read-only comparison stopped on an intermittent request failure, retained its page and resumed successfully. A later step stopped again; the current preview is retained for continuation and is not a completed sync. No proposed changes were applied. Browser logs also reported service-worker registration being redirected behind Access. Installed-PWA/offline behavior on the private host therefore remains unverified and needs a separate Access/static-worker registration pass; do not claim that the existing compiled-worker tests certify the live Access-protected PWA.

The initial upload with the hostname disabled reported error 10007 while configuring that disabled hostname; the version had uploaded successfully. After Access was configured and the production hostname enabled, subsequent Wrangler deployments completed successfully. Final deployed version: `17ffc6a3-2b65-4180-9133-5042b3af9065`. Verification passed 184 unit/database/runtime tests plus 3 compiled service-worker tests, with zero type-check errors or warnings. A private scan of built assets found zero configured credential matches. Screenshot: `screenshots/trakt-connected-live.png`.

No commits or pushes were made.
