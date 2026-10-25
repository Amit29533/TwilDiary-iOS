# Native sign-in and database availability

The production database returned Cloudflare D1's explicit free-tier daily row-read-limit error on 23 October 2026. The old app validated the Access cookie by reading `/api/workspace`; this database failure prevented saving a successfully authenticated session and displayed a generic change-failed message on the sign-in screen.

## Fix

- Sign-in now opens and validates `/api/session`. The backend verifies the same Cloudflare Access owner as before, without touching D1. The response contains only `authenticated: true`.
- The credential is saved to device-only Keychain storage after session validation. Database loading happens afterward, so a quota failure preserves the authenticated session.
- Before the first complete workspace loads, the app shows an explicit unavailable state with Retry and Sign out. An outage cannot masquerade as an empty diary. Failed later refreshes retain the previous complete snapshot.
- Read/write quota errors carry a reset timestamp, shown in the device's local time. Other HTTP server errors, including plain-text 503 responses, no longer imply an expired login. Authentication rejection still requires sign-in.
- Removed the extra workspace read used during authentication and the duplicate refresh triggered when switching from the sign-in screen to tabs.
- The shared backend's episode spoiler checks now use the existing watch-progress index instead of repeatedly scanning unrelated watch history. No schema or diary records were changed.

Cloudflare's limit is account-wide and [resets at midnight UTC](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/), which is 05:30 IST on 24 October for this incident. Handling this error does not raise the quota or restore database access before the reset. The query improvement reduces avoidable reads; it does not establish which workload consumed the account's quota.

## Build and verification

- Native app source: `fed4b14e640ed1b9ebffbfbc7e5fe3b5c78c6ec4`, build number 2.
- [Native build and test run](https://github.com/Amit29533/TwilDiary-iOS/actions/runs/39988206745) completed successfully.
- Debug simulator and Release physical-device compilation succeeded. All 16 native checks passed: seven core tests, seven new session tests and two iPhone UI tests. Session tests cover quota handling, successful/empty-diary loading, prior snapshot preservation, rejected authentication, Keychain-save failure, write-quota reset dates, and unexpected HTML. Home and title-detail screenshots from this run were also visually reviewed.
- Shared backend: `01aca75`, 346 unit tests plus three built-service-worker tests passed; Svelte/TypeScript checks and production build passed. Local authenticated session checks returned 200 without a database query. Unauthenticated production requests still redirect to Cloudflare Access.
- Downloaded IPA SHA-256: `f1ff083715f577305607367f9d37d7a80ce2411255e2d7a1980196f6c7dc97c0`. Verified against the workflow checksum, bundle identifier, build number, minimum iOS 26.0, Payload structure and arm64 Mach-O executable.

The CI session tests use an in-memory credential store and stubbed HTTPS responses. They never log into the owner's account or modify live diary/Trakt data. Physical LiveContainer sign-in remains a separate device verification step. Local browser testing was unavailable because the tool continued to report browser use disabled even after a fresh runtime reset.
