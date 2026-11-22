# Arena integration into the current UI

**Release/merge gate: HOLD. See [the updated review](ARENA-PREBUILD-REVIEW.md) and [regression evidence](STRICT-REGRESSION-2026-11-03.md) for repairs and remaining native/live verification.**

Integration branch: `codex/arena-ui-integration`.
Parents: current UI `b52f3e0` and Arena PR #12 `53daceb`.

## Preserved behaviour

Five tabs (Home, Library, Glance, Search, Profile), nested Statistics without Fun facts,
personal profile and avatars, the approved Home cards and inline episode dates,
Person/Cast/Character/Voice Actor native routes and compact ratings, and status-area-only blur.

## Integrated capabilities and repairs

- Calendar through Profile Tracking; collection tags through the
  existing Library filter sheet and title Notes sheet. The notes sheet can expand.
- Provider connection screens, custom API settings, diary import, critic ratings and metadata refresh.
- Corrected native watch mutation argument shapes and Trakt bulk snapshot bookkeeping.
- Supported transport-failed title edits and watch actions persist before optimistic publication.
  Relaunch projects the queue over the authoritative cache. Foreground/reconnect/background replay
  preserves operation IDs, checks versions, remaps temporary event IDs and keeps conflicting intents.
  Unsupported operations stay online-only. Pending backend edits cannot fan out to external providers.
- Pending edits show explicit device-only status, retry, and confirmed discard controls. Hosted imports
  publish after a server receipt; an unsuccessful upload no longer looks imported.
- Live Activity has a real embedded WidgetKit extension. Background identifiers and modes are
  explicit plist arrays; handlers register at launch and cancel their work on expiration.
- Combined delta reads use server-issued cursors and fall back to the existing revision/full snapshot
  route with an older deployment. Future cursors require a full refresh.
- Session signing requires an independent 32-character-or-longer server secret; passcodes are never
  signing keys. Persisted, bounded attempt counters throttle alternative sign-in. Provider vault v2
  uses HKDF-separated AES-GCM key material and randomized authenticated encryption.

## Deployment requirements

This integration does not publish a server or apply production database changes.
Before enabling alternative sign-in, apply `0024_auth_attempts.sql` and configure a randomly
generated `DIARY_AUTH_SECRET` (at least 32 characters), or a strong existing `TRAKT_TOKEN_KEY`.
Personal access tokens must have at least 32 characters. Existing Cloudflare Access remains supported.
Legacy Arena vault ciphertext is deliberately not decrypted with weak fallback secrets; reconnect
providers when moving from that draft format. Never put secrets in source or Codemagic logs.
Apply custom SQL migration `0025_history_display_order.sql` for the history-query improvement.
Preserve its expression index when rebuilding watch-events; the current Drizzle generator cannot
correctly serialize this expression, so the index is maintained as custom SQL.

## Verification

The dedicated Codemagic workflow is `native-ios-arena-integration-check` (build 67).
It runs the entire Core and app unit suites, the complete native UI target and simulator performance checks,
and unsigned device packaging including the WidgetKit extension. Evidence is retained on failures.
Native CI results and any remaining integration issues must be recorded before merging to main.
No physical-device or live external-provider acceptance is claimed by fixture tests.
