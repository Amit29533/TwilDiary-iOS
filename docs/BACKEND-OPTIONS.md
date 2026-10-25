# Free backend choices

> Historical comparison, superseded later on 21 October 2026. The owner selected Cloudflare Workers/static assets + D1/Drizzle + Cloudflare Access, with TMDb poster hotlinks and R2 deferred. See [the current architecture](ARCHITECTURE.md). The alternatives below are research context, not setup instructions.

Researched 21 October 2026. No backend selected or provisioned. Owner requires no paid plan and has an existing Cloudflare R2 bucket. Free allowances and provider terms can change; check the actual accounts before setup.

## Common proposed foundation

- Netlify hosts the new SvelteKit/TypeScript app and bounded server endpoints.
- A relational database stores catalog identities, personal state, episode history, mappings, and durable work.
- IndexedDB stores owner-scoped device cache and pending operations for fast repeat opening and offline use.
- R2 can store private note images and backup objects. File access goes through authorized short-lived URLs, not public diary attachments. Keep private paths and tokens out of object names and client bundles.
- Credentials and site identity come only from the new setup. Do not read old site secrets.

R2 Standard currently includes 10 GB-month storage, 1 million Class A requests, and 10 million Class B requests monthly, with free direct egress. Infrequent Access does not get this free allowance. Existing bucket usage shares the account allowance; overage is billable. Application-side upload/retention limits reduce exposure but are not an account-wide billing cap. R2 is useful for files, not a replacement for transactional episode storage.

## Options

| Choice                                       | Current free allowance relevant here                                                                                                                                | Operational tradeoff                                                                                                                                      | Assessment                                                                                    |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Netlify Database + Identity + R2             | Netlify Free has 300 shared credits/month; database compute and bandwidth consume the same credits as hosting/functions. Identity has no added fee on credit plans. | Fewest new accounts; database sleeps after 5 minutes on Free, and frequent scheduled polling can consume shared credits.                                  | Simplest account setup, less predictable room for background sync under a strict free budget. |
| Supabase Free Postgres + Auth + Netlify + R2 | 500 MB database, 5 GB egress, 50,000 monthly active users; pauses after one week of inactivity.                                                                     | Integrated login and relational storage, separate DB quota; requires another service/account and correct owner policies. No paid-plan backup assumptions. | Strong fit for one daily user, subject to owner's choice and available free project slot.     |
| Neon Free Postgres + Netlify Identity + R2   | 1 GB database storage and 100 CU-hours/month per project; free compute scales down after 5 minutes inactive.                                                        | Separate DB quota and simple SQL boundary; still need login integration; waking database can delay first online reconciliation.                           | Good lean SQL alternative, with more integration work than bundled Auth.                      |

These are published allowances, not measured workload predictions. A private diary with bounded metadata/image usage may fit free tiers, but cannot be promised unlimited or permanently free service capacity. All options still use Netlify hosting/function quotas.

## Recommendation pending owner's decision

For this single-user daily app, propose Supabase Free for database/login, Netlify Free for frontend/server integration, and the existing R2 bucket for attachments/backups. This separates database usage from Netlify's shared hosting budget and provides managed authentication without building an auth service. The weekly inactivity pause is a recovery consideration if the owner stops using the app.

If keeping infrastructure within Netlify is more important than separating quotas, Netlify Database + Identity is viable. Use bounded sync on open/manual requests and conservative scheduling, not a continuous database heartbeat. Do not fall back to the old monolithic Blobs document to avoid selecting a database.

The old app's no-Supabase constraint has not been overridden by a confirmed v2 choice. Do not install, provision, or connect any option until the owner decides.

## Cost-aware design for every choice

- Cache last-known Glance locally; backend wake-up does not block the cached first screen.
- Page/index queries; send only changed records and selected details.
- Batch Trakt work, use last-activity checks, backoff, and a bounded schedule. No keepalive requests to defeat sleeping/pausing rules.
- Compress and size note images, cap attachments, and make backups incremental/bounded where practical.
- Expose last backup/sync success and usage estimates; do not claim an in-app meter is the provider's authoritative bill.
- Before enabling R2 writes, agree namespace, retention, existing bucket usage, access credentials, and usage controls. Do not publish the bucket or alter other objects.

## Sources

- [Netlify pricing](https://www.netlify.com/pricing/)
- [Netlify Database billing and limits](https://docs.netlify.com/build/data-and-storage/netlify-database/billing-and-usage/)
- [Netlify Identity availability](https://docs.netlify.com/manage/security/secure-access-to-sites/identity/overview/)
- [Supabase pricing](https://supabase.com/pricing)
- [Neon pricing](https://neon.com/pricing)
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/)

Netlify's database documentation still includes transitional storage-pricing wording referring to July 2026; verify actual dashboard billing rather than interpreting that date as a continuing free-storage promise.
