# Arena integration: pre-build review

Updated 3 November 2026. Branch `codex/arena-ui-integration`, checkpoint `3eab289` plus working-tree repairs. This replaces the original blocker list; repaired findings below are no longer outstanding source defects.

**Hold release/merge. Local prerequisites are complete; the candidate is ready for the native test workflow.** See [regression evidence](STRICT-REGRESSION-2026-11-03.md) for numerical results and remaining runtime gaps.

## Reused app code

The current native five-tab shell, Search/Profile and nested Statistics remain. Home/History retain `HomeMediaCards`, the shared `WatchActivityCard`, inline episode/date footer and existing event projections. Profiles retain `PersonProfilePage`, `ProfileFacts`, biography formatting, compact ratings and native AniList/TMDB routes. Scrolling retains the status-inset-capped `FeatheredHeaderBackdrop` and edge-to-edge container. Delivery reuses existing guarded APIs, operation IDs, Trakt review, workspace revisions, protected cache and Keychain session boundaries. Web screenshots are not native redesign proof.

## Reproduced defects repaired

- Atomic Keychain provider envelope; denied storage cannot fall back to plaintext or publish unsaved credentials.
- Encrypted vault v2: explicit field patches/clears, revision CAS, generation-aware conflict choices, old-server/HTML rejection and protection against mismatched client/token pairs.
- Durable per-request provider checkpoints and uncertain-history markers. Missing mappings, unsupported operations, malformed item counts and rejections remain pending. Unsupported titles do not block unrelated mapped titles. Native direct transport rejects redirects and checks connection changes before acknowledgment.
- Actual read-only connection tests, honest pending/error/import receipts and no silent provider enablement after manual web sync.
- Atomic guarded title/tag edits and normalized limits.
- Atomic archive write batches, bounded ownership preflight, local version increments and safe repeat imports. Conflicting title/provider/episode/watch identities are rejected.
- Bounded RFC4180-style CSV scanning, Unicode-safe/source identities, repeated watches and local-day time zones. Missing dates remain unknown.
- The archive endpoint reuses the shared streaming JSON reader with an explicit 8 MiB byte limit; it no longer buffers an unlimited request or counts UTF-8 characters as bytes.
- Full-date Simkl requests, null new-account activity, explicit failure for unknown envelopes or unverified full WeTrakr pages, and storage-failure propagation.
- Server-owned web delta cursors. Live web startup no longer imports sample/preview data merely because a migration marker is absent; existing offline edits can still replay.
- Data-free web sign-in shell, protected private APIs and internal-only return paths.
- Custom history index `0025`, full-outbox background completion checks and sign-out activity/task cleanup.
- Native compiler repairs now pass the simulator app/test build at `8c65f4a`, including ActivityKit concurrency and correct operation/event mutation identities. Runtime fixture corrections preserve sync/data assertions while isolating session tests from host Keychain state.

## Remaining gates

1. The latest native run passed all **114 Core tests** and compiled the simulator app/test targets. Its **316 app test methods** had six failed methods (16 assertion failures): obsolete navigation expectations, non-isolated Keychain access, and two fixtures bypassing confirmed-snapshot loading. Those fixtures are corrected, with runtime revalidation pending. UI suites, rendered geometry, launch/scroll metrics, screenshots, unsigned device packaging and Widget embedding remain unverified. Parser checks are not compilation.
2. Real accounts remain read-only. Trakt live reads returned external HTTP 403. WeTrakr, Simkl and MDBList are fixture-only, as instructed. No provider refresh/write was attempted.
3. Some removal/favourite/status operations and MDBList history/rating delivery remain unsupported/pending. Ambiguous history needs reconciliation. WeTrakr pages at the unverified 1,000-row limit reject explicitly. Fixtures do not certify live contracts.
4. Production is unchanged. Alternative sign-in needs independent strong secrets and migration `0024`; the index needs `0025`. Hosted maximum-import CPU/plan limits are unverified.
5. Production dependency audit is clear. Full toolchain audit reports four low entries from one unpatched build-tool [deepmerge advisory](https://github.com/advisories/GHSA-gcqx-w48m-w2h4). The advisory lists no patched release. npm's obsolete framework downgrade was not applied.

The old successful `b52f3e0` build does not validate this integration. Backend timings do not establish native FPS, battery or background delivery.
