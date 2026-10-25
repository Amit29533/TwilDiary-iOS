# Research and selective reuse

Reviewed 21 October 2026. Plekt refers to the previously supplied `Lasikiewicz/plekt` project. Behavior and architectural lessons inform new work; no Plekt implementation has been copied.

## Plekt lessons worth applying

| Observation                                               | Application to Twil v2                                                                                  |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Artwork and useful actions appear early                   | Keep Glance compact and detail pages readable before presenting edit forms                              |
| Local cached page shells paint before metadata enrichment | Cache owner-scoped summaries; progressively enrich sections without remounting artwork or losing scroll |
| Lazy routes, pages, and season details                    | Separate the first page from the full collection and load seasons on demand                             |
| Stable movie/show/episode routes                          | Make details linkable, reloadable, and compatible with back/forward navigation                          |
| Event-level history and provider identity                 | Model episodes and rewatches directly instead of treating a season cursor as a watch ledger             |
| Durable provider work separate from local actions         | Save locally/canonically before remote delivery; expose retries and sync status                         |
| Incomplete snapshots cannot clear missing ratings         | Require complete validated snapshots before destructive reconciliation                                  |
| Upcoming episodes with cached month ranges                | Add an efficient agenda after core progress is reliable; do not block startup on calendar construction  |

Plekt uses an always-running Node/SQLite server. Its in-process scheduler and local artwork files cannot simply be transplanted into a Cloudflare Worker. Twil's hosted jobs need persisted work, bounded invocations, and free-plan budgeting. The owner's local-Wi-Fi Plekt experience is not a controlled performance comparison with a cloud-hosted app.

Features to evaluate later rather than silently add: Plex/Jellyfin/Emby automatic playback, Seerr requests, cast/person exploration, playback resume, provider playlists, and multiple metadata providers. Trakt sync has already been requested. The owner's scanner and notes remain first-class features even though Plekt emphasizes server integrations.

## Old Twil lessons

| Old component / behavior                                                           | Decision                                                                                                           |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| PowerShell discovery, category aliases, selected-drive scan, local recovery output | Candidate for isolated reuse after review; retain no Python requirement, cycle protection, and partial-scan safety |
| Scanner pairing and evidence merge                                                 | Reimplement around the new API/auth model; preserve narrow scanner permissions and history protection              |
| Filename/IMDb matching, duplicate safeguards                                       | Port only small deterministic rules with tests; do not import the old orchestrator                                 |
| Backup and Excel formats                                                           | Preserve via explicit migration/interchange adapters and round-trip fixtures                                       |
| Apple Home Screen icon fix verified by owner                                       | Preserve the working technique selectively, then validate output and physical iPhone behavior again                |
| Notes/image notes, tags, favorites, Trash and restore                              | Rebuild as small features on the new persistence layer                                                             |
| Season cursor and title-level watch dates                                          | Replace with explicit episode records/events; migration must not invent per-episode dates                          |
| One private JSON state fetched and rewritten                                       | Replace with indexed records, transactions, paged summaries, and on-demand detail                                  |
| Fourteen layered stylesheets and central DOM orchestrator                          | Rebuild using shared tokens, accessible components, route modules, and isolated feature logic                      |
| DOM-only progressive library rendering                                             | Keep gradual rendering, but also page data at the API boundary                                                     |
| Scanner file presence separate from viewing                                        | Preserve as a hard invariant                                                                                       |

No old application source has been copied into this checkout. The new domain functions and tests reimplement the required behaviors. Existing tests are evidence for behavior, not a guarantee that a new implementation is correct.

## Scanner requirements to retain or confirm

Confirmed in this conversation: Windows scanner with drives/folders mapped to titles and seasons.

Existing behavior to propose for compatibility: PowerShell 5.1, selected fixed/removable drives, discovery of Media Server / Media Acess Server / Media Access Server, category aliases, multiple/nested roots, skip reparse points, local recovery file, paired uploads, manual mismatch review, multiple locations for one title, and protection of personal fields.

New improvements proposed for review: stable volume identity in addition to drive letter; explicit scan coverage; mapping confidently recognized season/episode filenames; no guessed match for ambiguous anime numbering; separate unavailable/unknown/missing evidence; reviewable drive reassignment.

## Sources

- [Plekt architecture](https://github.com/Lasikiewicz/plekt/blob/main/docs/architecture.md)
- [Plekt detail pages](https://github.com/Lasikiewicz/plekt/blob/main/docs/media-detail.md)
- [Plekt rating reconciliation](https://github.com/Lasikiewicz/plekt/blob/main/docs/personal-ratings.md)
- [Plekt upcoming](https://github.com/Lasikiewicz/plekt/blob/main/docs/upcoming.md)
- [Official SvelteKit Cloudflare adapter](https://svelte.dev/docs/kit/adapter-cloudflare)
- [Cloudflare Workers SvelteKit support](https://developers.cloudflare.com/workers/framework-guides/web-apps/sveltekit/)

Local old-app evidence: `PROJECT_BRIEF.md`, `shared/episodes.js`, `shared/locations.js`, `shared/trakt.js`, `shared/model.js`, `public/Scan-Twil.ps1`, scanner/availability tests, and `docs/TWIL-VS-PLEKT-2026-10-20.md` in the original checkout. The original brief's Netlify Blobs/Identity decisions belong to the old app. The owner has now selected Workers, D1/Drizzle and Access for v2.
