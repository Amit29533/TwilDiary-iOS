# TwilDiary for iOS

This is a SwiftUI application, not a web-view wrapper. The audited Svelte app and Cloudflare backend remain in [Amit29533/TwilDiary](https://github.com/Amit29533/TwilDiary). The first native milestone mirrors the existing black canvas, accent themes, artwork cards, Library filters, Glance progress controls and title progress panel.

## Build

Requires Xcode 26 or newer and an iOS 26 simulator/device. On macOS:

```sh
brew install xcodegen
cd TwilDiary-iOS
xcodegen generate
open TwilDiary.xcodeproj
```

The generated project is intentionally ignored; `project.yml` is its source. The local Swift package contains the Codable API contract and independently testable diary calculations:

```sh
swift test --package-path Packages/TwilDiaryCore
```

The **Native iOS** GitHub Actions workflow runs on `macos-26`, tests the package, generates the project, runs native UI tests on an available iPhone simulator, and compiles a Release build for physical iOS devices. Simulator application and `.xcresult` screenshot/test reports are retained for seven days. CI uses synthetic data and never signs in to the owner’s live diary.

The workflow packages the Release device build as **TwilDiary-LiveContainer.ipa**, with a SHA-256 checksum, in the **TwilDiary-LiveContainer-IPA** artifact. This is an unsigned IPA intended for import into your configured LiveContainer, which handles guest signing. The archive contains `Payload/TwilDiary.app`; it is separate from the simulator `.app`, which cannot run on an iPhone. Import through LiveContainer's plus button, following its [official guide](https://github.com/LiveContainer/LiveContainer#installing-apps). Physical device compatibility and sign-in still need testing inside LiveContainer. TestFlight or direct Apple-signed distribution would require a separate signing setup; no Apple certificates are needed in CI for this unsigned artifact.

## Existing backend and sign-in

The app uses `https://twildiary-v2.amit29533.workers.dev`. No API, OAuth, Cloudflare service-token or provider credential is embedded in the binary. A nonpersistent WebKit sheet performs the existing Cloudflare Access login. Only the secure `CF_Authorization` application cookie scoped to the configured backend is transferred into device-only Keychain storage. Native URLSession requests send that cookie exclusively to the HTTPS backend; redirects are rejected. The backend retains its Access JWT validation and same-origin write checks. The sheet must be tested against the actual Access identity provider on a physical iPhone; some identity providers restrict embedded browser sign-in. If this provider does, the next step is a system-browser PKCE session bridge, not disabling Access.

Workspace sections are paginated in full and published together. A failed request preserves the previous complete snapshot. Mutation controls wait for confirmed responses. Watch operations retain retry identities in memory; status changes use the existing atomic progress endpoint and Undo receipts. Pending writes are not persisted across process termination yet, so the app has no offline write queue. Refresh after a terminated/uncertain request before continuing.

Sign-in validation uses the authenticated, database-independent `/api/session` endpoint. Temporary database failures keep the session and show a Retry screen until the first complete diary loads. Cloudflare daily quota errors show their reset time in the device's local time. See the [sign-in recovery report](docs/SIGN-IN-RECOVERY-2026-10-23.md).

## Port coverage

| Area | First milestone | Remaining parity work |
| --- | --- | --- |
| Navigation | Five native tabs, per-tab navigation stacks, native menus, six accent themes | Scroll restoration across every deep-link and relaunch |
| Home | Continue watching, Queue, Disk Map, weekly summary, planned titles, recent history | Explore shortcut, pick-for-me, new-episode section, weekly mini-chart |
| Library | Artwork grid/list, category/status/genre/disk filters, search, ordering, public TMDB badges | Trakt public-rating preference, bulk actions, genre sections, edit/Trash restore |
| Glance | Per-title server progress, next watch, latest-watch removal, Undo | Native swipe-to-watch, waiting-for-new-episodes grouping and sorting |
| Title | Clear poster/backdrop, public/personal ratings, notes, favorite, Queue, season menu beside Episodes, server locations collapsed | Cast/recommendations, custom watch dates, rewatches, individual episode selection, spoiler setting |
| Stats | Dated watch time, calendar period/year menu, daily chart selection, backlog, top-five expandable genres | Existing rolling-range bar, comparisons, streak heatmap and complete calculation parity |
| History/files | Search, calendar filters, full loaded history, location paths | Exact date/range controls, file-map editing/scanner review |
| More | Accent selection, native setting rows, local sign-out | Trakt sync review, import/export, remaining preferences and diagnostics |

The synthetic simulator fixtures are reachable only with the `--ui-testing` argument in Debug builds. They are never substituted for real backend data. Screenshots from CI are visual review evidence, not certification of physical iPhone sign-in, accessibility, gestures or feature parity. The native port is not yet a replacement for the audited web release.
