# Library and history backend increment

21 October 2026. Local development only. This is an implementation/test report, not a production-readiness claim.

This is the earlier library/history increment. The subsequent [metadata/workspace report](METADATA-WORKSPACE-REPORT.md) updates TMDb and frontend integration progress; the verification below describes this earlier snapshot.

## Implemented API surface

All routes require the verified owner in server locals, in addition to the global Cloudflare Access hook. There is no development bypass for API writes. Missing Access/DB configuration fails closed. Responses use private/no-store caching. JSON writes are bounded to 128 KB and reject unknown input fields.

| Method and route                      | Behavior                                                                                                  |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `GET /api/titles`                     | Bounded, indexed keyset pages; title search; status/category filters; `trash=1` selects Trash             |
| `POST /api/titles`                    | Creates a manual title using a stable caller-provided ID; retry cannot create a second copy of that ID    |
| `GET /api/titles/:id`                 | Active title details, provider identities and season summaries                                            |
| `PATCH /api/titles/:id`               | Partial name/status/favorite/score/notes updates with `expectedVersion`; stale changes return 409         |
| `DELETE /api/titles/:id`              | Soft deletion with `expectedVersion`; retains history and relationships                                   |
| `POST /api/titles/:id/restore`        | Restores a trashed title with version checking                                                            |
| `GET /api/titles/:id/seasons/:number` | Number-ordered episode pages; unwatched names/overviews withheld by default; explicit reveal supported    |
| `POST /api/titles/:id/watches`        | Typed movie/episode watches, explicit unknown dates, intentional rewatches and durable operation receipts |
| `PATCH /api/watch-events/:id`         | Versioned revoke/restore of one watch; stale Undo cannot reverse a later unwatch                          |

Library pages default to 24 records and permit at most 60. Notes are omitted from list summaries. Cursors retain `(sortName,id)` and filter context so tied names and changed filters cannot silently skip a page. User-supplied wildcard characters are searched literally.

## Reliability findings and fixes

- A watch request that finds an already-watched episode also needs a durable receipt. Without one, a later network retry could restore the episode after the owner unwatched it. The new `watch_operations` table retains that outcome.
- Watch insertion and its receipt commit in one D1 batch. Injected receipt-write failure rolls back the viewing too.
- Conditional inserts prevent simultaneous requests from creating accidental rewatches. Intentional rewatches require an explicit flag and a separate operation identity.
- Undo uses an increasing event version rather than a timestamp alone. Two actions in the same millisecond cannot make an old Undo appear current.
- Reviewed the generated event-version migration. Replaced its table rebuild with an additive column change, then tested a populated upgrade to preserve watches, receipt foreign keys and IDs.
- Fixed correlated episode-watch SQL qualification and literal search escaping after integration tests exposed the errors.

## Evidence

- 48 automated tests pass across domain, database, Access, API and integration suites.
- Drizzle's actual D1 driver executes repository SQL against native SQLite in the integration harness. The harness supplies D1-style prepared statements and atomic batches; it is not a remote Cloudflare deployment.
- Migrations 0001 and 0002 also applied successfully to Wrangler's local D1 database.
- Svelte check and the Cloudflare Workers build pass, including the final UI-only changes, with zero diagnostics.
- Tested stale title writes, tied-name pagination, literal wildcard search, Trash/restore preservation, spoiler withholding, concurrent retries, no-op replay after unwatch, explicit rewatches, targeted Undo, atomic rollback, invalid payloads, request size limits and missing-owner access.

## Still outstanding

The `/preview` UI remains isolated IndexedDB sample data. It is not silently switched to the new backend. Connecting a real empty workspace to these endpoints, TMDb metadata search/import and poster mapping, metadata correction/merge, lists/tags, bulk actions and Trash UI remain Phase 2 work. Permanent purge has not been implemented or run.

The Windows scanner, migration/import, Trakt, durable offline queue, service worker/iOS icons, account setup and real-device testing remain later phases. No claim is made that the whole app is complete or opens instantly on an iPhone.

The owner confirmed local-first development; no hostname/Access application is set up yet. No Cloudflare account resources, DNS, old Netlify project, production data, credentials, commits, pushes or deployments were changed.
