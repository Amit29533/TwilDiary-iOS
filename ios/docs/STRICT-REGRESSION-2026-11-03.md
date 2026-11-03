# Strict regression run â€” 3 November 2026

Active branch: codex/arena-ui-integration. Starting checkpoint: 2d538b7.
Owner constraint: real accounts are read-only; write tests use isolated seeded databases.
Production deployment and merge remain gated on verification.

## Execution phases
1. Repair and reproduce audit blockers: credential storage, vault CAS, archive/CSV, atomic tags, delta cursors, provider acknowledgement/retry.
2. Full local static/backend/database/auth/service-worker tests and isolated Worker HTTP contracts.
3. Per-service protocol/fault/conflict matrices and read-only live metadata/account checks where credentials exist.
4. Deterministic load, latency, memory, concurrency and failure benchmarks with raw JSON results.
5. Xcode/Core/app tests, full native UI regression groups, compact/large accessibility geometry and performance measurements.
6. Review actual artifacts, compare compatibility, rerun affected checks after fixes, publish complete results and gaps.

## Current progress
- Baseline audit: 531 backend tests, 3 service-worker tests, 29 Python helper tests passed; 177 Swift files passed syntax comparison. This is not native runtime proof.
- Credential storage repair implemented: one atomic Keychain envelope, no new plaintext fallback; native tests added, execution pending.
- Atomic rating/tag rollback and stale-version/normalization regressions: 2/2 passed.
- Server vault field patches and compare-and-swap regression: passed; 16 targeted existing/new tests passed.
- Native/web vault compatibility and remaining audit repairs in progress.

All reported provider writes must be fixture transports or local seeded DB operations. Never put tokens, private diary payloads or account-identifying rows in committed evidence.

## Checkpoint A — local results before native CI
- Full backend/unit run: **550 passed, 0 failed**, 40,379.5 ms. Four subsequently added vault-client tests: **4 passed, 0 failed**, 197.0 ms. Counts are separate until the next complete rerun.
- Production build passed; Svelte/TypeScript check **0 errors, 0 warnings**. Existing Node FORCE_COLOR/NO_COLOR environment notices remain.
- Swift parser comparison: **213 source/test files**, no newly introduced parse errors. This does not establish semantic compilation or runtime correctness.
- Targeted delivery/import/vault suite: **32 passed**, plus timezone/shared-parser rerun **9 passed** (overlapping tests; do not add these to totals).
- Native workflow expanded from selected UI cases to the complete UI target (82 methods including two performance methods), with full Core/app tests and an unsigned device build including the Widget extension. Native execution is pending.

### Repairs under test
Atomic Keychain configuration envelope; versioned vault field patches/CAS and explicit conflict choices; import rollback, Unicode/source identities, ratings scales and local-day preservation; atomic tags and stale-write guards; server-owned web delta cursors; per-request provider checkpoints and item receipts. Ambiguous history requests stay pending for reconciliation instead of automatic duplicate replay. Unsupported provider operations stay pending with an explanation; they are not reported as synced.

### Capability limits requiring explicit reporting
WeTrakr documentation/spec access returned HTTP 403, and MDBList's detailed contract was not available as a machine-readable spec. Fixture tests establish queue safety, not live write compatibility. Live provider writes are prohibited by the owner's read-only constraint. All full-sync claims remain gated on service-specific evidence.
