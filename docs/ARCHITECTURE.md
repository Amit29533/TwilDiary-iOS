# Selected architecture

Confirmed by owner on 21 October 2026. This replaces the earlier Netlify/Supabase recommendation.

| Layer              | Choice                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| UI and routes      | SvelteKit 3, Svelte 5, strict TypeScript                                                                |
| Hosting            | Cloudflare Workers with static assets; `@sveltejs/adapter-cloudflare`                                   |
| Database           | D1 / SQLite, Drizzle typed schema and queries                                                           |
| Private access     | Cloudflare Access, Google identity provider, owner-only allowlist; signed JWT revalidated in the Worker |
| Metadata           | Server-side TMDb API; poster paths hotlinked to TMDb image sizes                                        |
| Files              | Windows scanner uploads mappings/evidence, not media files                                              |
| Device persistence | Separate preview IndexedDB now; owner-scoped cache and operation queue in the PWA phase                 |
| Object storage     | R2 deferred; no bucket dependency or image-upload endpoint                                              |

## Boundaries

- Components own UI interactions; domain functions own episode/history and availability rules.
- `src/lib/server` owns D1 access, Access verification and future provider credentials. It cannot be imported into the client bundle.
- Each request receives its D1 binding explicitly. No private global state or JSON-document database.
- Catalog identity, personal watches, file evidence, and provider delivery are separate. Actual watch dates and edit clocks never substitute for one another.
- Live title/episode reads will page/index queries; notes and season lists load on demand. Cached first paint is independent of full metadata synchronization.
- D1 batches will be used for atomic state-plus-job writes. Do not assume a long-running Node process or a generic interactive Postgres transaction exists.

## Current implementation

The sample workspace demonstrates the intended daily UI and stores changes locally. The actual local D1 diary is empty. Owner-guarded library/history APIs, versioned edits, Trash/restore, paged season reads and atomic watch receipts are implemented and integration-tested. The preview is not yet wired to them. The schema now has ten tables, including operation receipts; see the [Phase 2 report](PHASE-2-REPORT.md) for the API contract and verification limits.

Access verification checks the assertion signature against the configured team's JWKS, issuer, application audience, expiry, application token type and owner email. It never trusts an unsigned email header. Unsafe browser requests require the same Origin. Missing configuration fails closed in production. The local Vite development build permits only the non-API UI preview without credentials.

The scanner endpoint will be separately implemented with its own scoped credential and an appropriate narrow Access service policy. Do not expose an unauthenticated upload bypass or use an owner session token inside the scanner. That endpoint does not exist yet.

## Fresh hosting setup, when the owner is ready

1. Select the owner's new Worker/hostname and create a dedicated D1 database. The zero UUID in `wrangler.jsonc` is deliberately a local-only placeholder.
2. Apply migrations only to that new database after local tests. No old library is seeded or imported automatically.
3. Configure the Access application for the entire hostname and Google sign-in, with an exact owner allowlist. Record the team domain and application audience.
4. Set `ACCESS_TEAM_DOMAIN`, `ACCESS_AUDIENCE`, `ACCESS_OWNER_EMAIL` and metadata credentials in the Worker environment. Never embed a TMDb token or Access secret in static code.
5. Keep alternate unprotected entry points disabled. `workers_dev` and preview URLs are off by default until their Access policy is explicitly configured.
6. Verify untrusted/missing/expired assertions, wrong-owner requests, session renewal and iPhone sign-in before real diary data is added.

No account login, remote database creation, Access policy change, domain change or deployment has been performed.

## Free-plan budget

Use Workers Free and D1 Free only. Current D1 Free allowances include 5 million rows read/day, 100,000 rows written/day and 5 GB total account storage. Row scans count, so indexes and bounded queries matter. These are provider quotas, not guarantees about this application's measured usage.

Avoid busy polling and background keepalive requests. Trakt jobs will be bounded and batched, with explicit retry state. Backups will initially be downloadable files and D1-supported recovery; do not require R2 to open the app. New image uploads remain deferred.

## References

- [SvelteKit Cloudflare adapter](https://svelte.dev/docs/kit/adapter-cloudflare)
- [Workers SvelteKit guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/sveltekit/)
- [Drizzle D1 driver](https://orm.drizzle.team/docs/sqlite/connect-cloudflare-d1)
- [D1 pricing and query accounting](https://developers.cloudflare.com/d1/platform/pricing/)
- [Validating Access assertions](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)
