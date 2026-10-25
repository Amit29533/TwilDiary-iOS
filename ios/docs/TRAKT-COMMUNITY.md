# Trakt community information — additive, not deployed

Native saved-title and catalog detail screens expose a right-side Information action. The sheet shows real overall Watchers, Plays, Collectors, Comments and Lists, followed by Trakt's positive/negative comment summaries, analysis date and analyzed-comment count. These values never fall back to personal ratings or locally generated opinions. Manual/unmatched titles offer an honest matching prerequisite; missing configuration, unmatched identity, empty summaries and provider failures remain distinct. Native previews use explicitly DEBUG-only synthetic data.

## Backend addition requiring deployment approval

Prepared GET `/api/trakt/community?kind=show|movie&provider=tmdb|trakt&id=<positive numeric id>`. It uses the existing ownerApi authorization boundary and private/no-store response headers. No D1 connection, schema migration, write or personal OAuth token is involved. Public app credentials remain on the Worker. Strict public path validation extends the existing Trakt transport only for numeric movie/show stats and sentiments. TMDB lookup requires both the exact media type and exact TMDB identity. Public stats/sentiments run concurrently, coalesce pending reads, cache bounded256 identities, retain valid partial responses, and briefly cache provider failures. Provider401 cannot expire a Cloudflare Access session.

Existing shared HTTP timeout10seconds and bounded2MB UTF-8 JSON decoding remain in force. Count/type/date/text bounds prevent incomplete totals or invalid summaries being presented as real. The app renders provider strings as plain SwiftUI Text, never HTML/Markdown. Native caching is memory-only, scoped to the private session, bounded32 titles, and resets on authentication/sign-out. Cancellation-ignoring old replies cannot publish. A missing deployed route produces a clear unavailable state rather than simulated live information.

**No deployment, hosted D1 operation or real-account mutation has been performed.** Deployment approval is still needed after the complete source/test/UI batch is reviewable; this document does not authorize one. No new secret is requested or stored. Existing TRAKT_CLIENT_ID configuration is reused.

Official contract evidence: [Trakt public API repository](https://github.com/trakt/trakt-api), `projects/client/src` schemas and movie/show endpoints, verified24October2026. GET `/shows/{id}/stats`, `/movies/{id}/stats`, `/shows/{id}/sentiments`, `/movies/{id}/sentiments`; sentiment payload carries good/bad arrays of sentiment text, analyzed_at and comment_count. No per-user play_count schema is substituted for public community totals. Provider availability/plan limits still yield honest unavailable states.

## Verification

Seven Node tests cover validated identity, counts, raw sentiment contract, exact identity resolution, concurrent/coalesced requests, partial provider401/cooldown, missing configuration/unmatched/empty states and owner authorization without D1. Full Node suite353/353 and Svelte/TypeScript check0errors/0warnings pass locally; production web build succeeds (one existing CLI NO_COLOR/FORCE_COLOR environment notice, no source compiler diagnostic). Five native unit tests and one native UI case are prepared; their macOS compilation/runtime/screenshot verification is pending. NativeUI fixture does not claim real Trakt availability.
