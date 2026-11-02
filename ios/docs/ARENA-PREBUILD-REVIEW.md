# Pre-build review of the Arena integration

**Decision: hold Codemagic, deployment and merge.** The user requested this audit before a native run.
The integration is reviewable on `codex/arena-ui-integration`; it is not a release candidate.
The existing production server and main branch have not been changed.

## Scope and reuse

Reviewed the complete change inventory against current UI commit `b52f3e0`, including Arena's
provider engines, native/web delivery paths, imports, authentication, vault, delta reads, screens,
model changes, tests and release configuration. This is over 100 files, largely inherited Arena code.
This was a source and local-test review, not a claim that every feature has run on an iPhone.

| Area | Existing code retained or reused | Integration |
| --- | --- | --- |
| Navigation | Current five-tab shell and native route types | Search/Profile stay; Statistics stays inside Profile |
| Home | Current hero, weekly panel, media cards and inline episode dates | Calendar is accessible through Profile, avoiding another crowded Home header action |
| Person pages | Current Cast/Character/Voice Actor pages, compact ratings and native links | No replacement with Arena's older layouts |
| Scroll appearance | Current status-area feathered blur and edge-to-edge scroll container | Used for new calendar/provider pages |
| Library | Existing query, filter sheet and Jellyfin presentation | Tags added to the filter sheet; untagged Jellyfin extras are excluded when a tag is selected |
| Title editing | Existing Notes sheet and version-aware editor | Collection controls use that sheet and the existing patch endpoint |
| Diary delivery | Existing `DiaryStore.perform`, `DiaryAPI`, protected workspace cache and index | Durable pending queue projects over the authoritative cache; original watch operation IDs survive replay |
| Server writes | Existing guarded `logWatch`/`patchTitle` paths and Trakt review machinery | Reused for normal writes/provider imports; new archive SQL needs further work below |

## Problems repaired during integration and this audit

- Resolved overlapping UI changes while retaining the approved current layouts.
- Corrected watch mutation labels/order, the missing provider-client method and duplicate ownership
  of provider acknowledgement. The store now owns acknowledgement/session checks.
- Corrected a missing Trakt bulk-send snapshot argument found by the combined tests.
- Added actual native backend replay instead of an unused enqueue helper: persist before publication,
  explicit device-only status, original operation IDs, conflict retention, dependent version/event-ID
  handling, retry and confirmed discard. Unsupported operations remain online-only.
- Hosted import no longer looks successful when upload fails.
- Replaced passcode-derived session/vault keys with independent strong signing material, added
  persisted bounded sign-in throttling, and used purpose-separated HKDF/AES-GCM for vault v2.
- Added a real WidgetKit extension and explicit background plist identifiers/modes, with launch-time
  registration. Device execution is still unverified.
- Added server cursors to the combined delta route and native consumer, with older-server fallback.
- Reproduced and fixed web offline helper behaviour that discarded 401 failures as completed,
  and failed to persist acknowledgements using default browser storage. Replay is serialized,
  keeps failed/dependent edits, requires a matching JSON receipt, and rejects redirects.
- Prevented Trakt and MDBList from sharing the native score cache after a source change; stale
  responses from an older source are discarded. Added a regression test.
- Aligned the app's collection-tag length check with the server, made calendar filters wrap, and
  retained the original Home section actions. Alternative sign-in reuses the existing date parser.

## Remaining merge blockers

### 1. Direct provider delivery can still falsely acknowledge work — P1

`MultiProviderSync.swift:1064` appends an entry ID even if its title has no usable mapping.
The switch also does not produce removal/revoke payloads for all mutation types; MDBList's native
transport does not send every payload the shared planner can produce. `DiaryStore.swift:772`
acknowledges every batch entry after the client returns. Web direct fan-out has similar assumptions.
HTTP success also does not yet validate each provider's per-item rejection receipt.

Required: explicit provider capabilities, acknowledgement only for represented/confirmed actions,
and durable per-request progress. A history request followed by a failing rating request must not
cause already-sent history to be blindly retried. Reuse the existing reviewed Trakt reconciliation
path where it already handles this, rather than treating a generic HTTP 2xx as complete sync.
Provider retry behaviour needs verification against their official APIs, not only mocks.
The [Trakt API reference](https://trakt.docs.apiary.io/#reference/sync/add-to-history/add-items-to-watched-history)
is one of the primary references reviewed; live account writes were not performed.

### 2. Secure-storage failure can fall back to plaintext preferences — P1

`MultiProviderSync.swift:284` removes a secret from the serialized preferences only when the
Keychain write succeeds. A failed Keychain write therefore leaves the original token/API key in
the UserDefaults payload. This is a concrete fallback in the code, not evidence that the user's
device has encountered it.

Required: never serialize secrets into preferences, surface secure-save failures, and retain
previously saved credentials safely. Test denied/locked Keychain cases before calling this secure.

### 3. Vault saves can erase another device's provider configuration — P1

`provider-vault.ts:164` replaces the complete encrypted document without a revision precondition.
Native settings push all local provider entries, including defaults on a new device.
A synthetic database reproduction confirmed that saving a different/partial configuration loses
the previously stored provider entry. Concurrent saves have no conflict detection.

Required: versioned field updates, explicit clear/disconnect semantics, and compare-and-swap conflict
handling. Do not silently combine defaults, omissions and deliberate removal into the same action.

### 4. Archive/CSV import is not yet safe enough for general use — P1

- `workspace-migration.ts:333` can change an existing title's personal fields while retaining the
  same version (`MAX(existing, imported)`). A stale editor can then still pass its old version guard.
- `workspace-migration.ts:474` commits independent chunks. A late constraint/network failure can
  leave a partial restore, without a resumable import receipt or explicit partial-completion result.
- Both `DiaryExport.swift:102` and `workspace-migration.ts:518` derive CSV identities from an ASCII
  slug/year. Different non-Latin titles or colliding normalized names can share an ID and merge.
  The two parsers also use different fallback IDs/default years and differ in date/watch handling.

Required: stable source identities (or a Unicode-safe collision-resistant identity), consistent
parsing/validation, safe version increments, and atomic or explicitly resumable restore semantics.
Do not advertise the CSV implementations as interchangeable yet.

## Additional corrections required before enabling the new features

- **Tag writes:** `library.ts:203` updates the title/version before writing `workspace_ui.tags` in
  another transaction. A failure can save only part of a combined edit. Make the guarded title/tag
  write atomic, and validate the normalized tag length rather than only the pre-normalized input.
- **Web delta cursor:** `live-diary.svelte.ts:157` still uses the client clock after a response.
  Consume the new server cursor and capture the initial revision before downloading pages, as in
  the native approach. Otherwise a change during the request can fall outside the next delta window.
- **Success UI:** provider screens can say "Synced" after swallowed errors or unsupported pending
  actions. Show confirmed counts and remaining/failed actions; distinguish configured from verified.
- **Web offline feature scope:** the safer generic offline helper is not wired into normal web writes.
  Do not claim complete web offline editing from the helper tests alone.
- **Background execution:** real wakeup, expiration, locked-device storage and Live Activity behaviour
  need native/device verification. A registered identifier and extension do not prove delivery runs.

## Evidence and limits

These remaining failures were reproduced locally against synthetic data only:

| Reproduction | Observed result |
| --- | --- |
| Two different Japanese CSV names with the same year | Only one resulting title |
| Import notes into an existing version-1 title | Notes changed; version remained 1 |
| Force the tag insert to fail during a combined rating/tag patch | Request failed; rating had already changed |
| Invalid late watch reference after a 40-title archive | Request failed; 34 titles had already been written |
| Clear a rating through the web direct-provider queue | Zero network calls; one item reported flushed and removed |
| Save a different/partial provider-vault document | Previously saved provider entry absent afterwards |

The existing passing suite did not cover these cases. They must become regression tests alongside
the repairs; passing the current suite does not override the reproduced failures.

| Check | Result |
| --- | --- |
| Combined backend/unit suite after review fixes | 531 passed |
| Focused changed wiring/provider/audit tests after UI cleanup | 31 passed |
| Svelte/TypeScript check | 0 errors, 0 warnings |
| Production web build | Passed; environment colour-variable notices only |
| Production service-worker tests | 3 passed against the latest production output |
| Release/helper Python tests | 29 passed |
| Swift source syntax comparison | No new syntax errors in the latest 177-file scan; this is not a Swift type check |
| Current integration Xcode compile, app/Core tests and UI captures | Not run; Codemagic deliberately held |
| Live provider writes / production migration / server deployment | Not performed |

The previously successful `b52f3e0` native build verifies the old current-UI baseline, not this
integration. Its screenshots and test counts must not be reused as evidence that Arena passes.
Fix the blockers, run the dedicated integration workflow, inspect its actual screenshots and
device package, then make the integration eligible for merge.
