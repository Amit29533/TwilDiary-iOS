# Native privacy inventory — 25 October 2026

Source review of the native App/Core and existing backend, not an App Store
submission or a statement about all deployed provider logging. No new data
collection, tracking prompt, analytics SDK, backend change or deployment is
introduced by this document.

## Required-reason API findings

| Current use | Purpose and boundary | Required declaration |
| --- | --- | --- |
| AppStorage/UserDefaults.standard in themes, layouts, rating/spoiler preferences | App-owned preferences, no app-group/global-domain access or export | UserDefaults / CA92.1 |
| ProcessInfo.systemUptime in PageHeader's RandomPick.tap | Elapsed time between logo taps; stays on device | SystemBootTime / 35F9.1 |
| WorkspaceCache resourceValues(fileSizeKey) | Bound an encrypted app-container file before reading it | This exact key is not in Apple's current listed timestamp APIs. Do not infer timestamp/disk-space collection from saved PC drive sizes. Recheck if this code starts reading timestamps or capacity. |

These mappings come from Apple's current
[required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Core source contains no direct UserDefaults/systemUptime/file timestamp/disk
capacity calls. Test and CI timing/file inspection are not shipping app APIs.
The manifest is packaged into the actual executable bundle and verified there
by the Release gate, per Apple's
[manifest placement guidance](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files).
Native62 physical Release logs confirm the required-reason manifest is in the
actual bundle. Complete official CM62success is verified; final IPA archive
download/independent GHA remain separate evidence.

## Data flows actually present

| Flow | Destination and storage | Label review |
| --- | --- | --- |
| Cloudflare Access authentication | Ephemeral auth-only WebKit; validated credential in device-only Keychain, credential header only to fixed private HTTPS API | Account identity and configured identity-provider retention need inclusion in the deployment review; no service token is bundled. |
| Watches, status, favorites, Queue, ratings, notes/manual titles | Existing authenticated Worker/D1; personal records stay associated with the diary | Product interaction and other user content for functionality; recommendation personalization uses diary/provider state. |
| Trakt authorization/sync | Existing backend PKCE and encrypted server tokens; trakt_connections stores username/account_id | User ID linked to account, functionality; optional sync does not imply anonymous collection. |
| Online search and artwork | Query to backend/TMDB; public artwork to image.tmdb.org; bounded local image/cache state | Review query/provider/CDN and deployed access-log retention before a definitive search-history disclosure. |
| Offline diary | AES-GCM app-container snapshot, complete file protection, backup exclusion, device-only Keychain key | On-device storage is not an off-device collection claim. |
| Export and path copy | Explicit user file export/share or local clipboard action | No automatic upload destination is selected. |

No advertising identifier, location/contacts/photo/microphone permission,
third-party analytics/crash SDK or tracking network is referenced in App/Core
source. This source finding does not certify external authentication providers'
policies or deployed Cloudflare log settings.

Apple distinguishes retained off-device data from transient request servicing
and maps generic notes to user content; its
[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
definitions guide the final labels. Do not use an empty collected-data list as a
claim that a diary stored in D1 collects nothing. Final deployment retention,
manifest/data-type mapping, built-bundle check and optional App Store labels are
still open. They do not require changing the current unsigned phone test path.

## Required-reason packaging follow-up — qualified62

Inspecting the delivered native54IPA confirms no PrivacyInfo.xcprivacy is present.
62adds the two reviewed app-owned API reasons above and NSPrivacyTracking=false.
It does not add an empty NSPrivacyCollectedDataTypes array: actual D1/provider
retention and final App Store labels remain a separate unresolved review.
XcodeGen explicitly copies the manifest as a resource. The Release packaging gate
now rejects missing/malformed manifests, duplicate/incorrect reasons and leaked
test resources.16CI-tool tests pass locally. Actual62macOS generated-project and
physical Release resource gates pass, including both required API reasons. This
does not finalize App Store data collection labels or external log retention.
