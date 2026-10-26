# Native62 owner feedback — 26 October 2026

Scope: native iOS experience. Owner reports the complete history import used
under 200k reads; this is owner-reported evidence, not a new analytics capture.
Cloudflare issues are considered resolved for this pass. Keep the D1-first
architecture, backend and hosted data unchanged. Stage1 redesign was reverted
by8154e77; do not restore its migrations, revision endpoint or pipeline.

Eight supplied videos were read locally and12frames each extracted/visually
inspected. Private sheets/manifest: .local/native62-phone-feedback-20261026.
No private video/frame/library data is committed. Times below identify the
source clip rather than promising frame-accurate performance measurements.

| Request | Evidence / implementation direction | Acceptance |
| --- | --- | --- |
|1 Tab bar returns late after Back |12:05:45clip shows destination returning before native bar. Give every root explicit visible tab chrome; verify completed/cancelled Back. | Pending native runtime |
|2 Information sheet drag stutters/text fades |12:07:21clip shows native title/content fading across sheet heights. Remove detent-dependent content/render work and stacked material; preserve translucent background/black cards. | Pending |
|3 Native Liquid Glass buttons throughout | Watch-time menu screenshot; audit semantic action controls, pills, menus and layout switches for real native glass styles. Keep poster/navigation card artwork readable. | Pending |
|4 Remove carousel overflow | Delete visible continuation overflow menu and its obsolete creation/state. Preserve native horizontal scrolling, selection restoration and accessibility. Update UI case to actual swipes. | Source updated, uncompiled |
|5 Scrambled/misleading episodes | Screenshot shows9–12while header says0/12during old quota failure. Existing numeric sort is correct; distinguish next-episode window, actual history and absent card data. Never display fabricated zero counts. | Pending |
|6 Reveal moves whole page |12:19:35clip shows long descriptions inserted under grid thumbnails. Decouple spoiler reveal from expansion and keep grid geometry stable. | Pending |
|7 Title/episode scroll stutters |12:24:44and17:02:57clips show header/content movement. Repeated history scans per row verified in source; add per-title/season indexes and isolate scroll chrome updates. | Index source updated, uncompiled |
|8 Buttons stutter |17:06:19clip shows repeated interactive Back starts/cancellations. Preserve system pop ownership; avoid asynchronous bar reconstruction and custom spring work on native controls. | Pending |
|9 Normal interactive tab swipes |17:08:21is Trakt reference: pages track finger. Existing root recognizer changes tab only on release, so it does not match reference. Needs actual interactive paging and child-gesture protection. | Pending |
|10 Remove manual creation everywhere | Remove search entry, modal and scanner option. Existing titles/data and backend APIs remain intact. Replace manual-creation UI case with absence/catalog-import checks. | Source updated, uncompiled |
|11 Library controls scroll away, progressive rendering | Move filter/order rows into Library scroll content below fixed header/category. Retain selection/sort and load visible content progressively without layout jumps. | Pending |
|12 Information button behavior |17:20:11clip shows delayed Information presentation and later content/background arrival. Keep responsive sheet presentation, single action owner, retained content and cached artwork. | Pending |
|13 Global latency/reloading/jitters | Production Artwork uses AsyncImage; add shared bounded decoded-image cache, off-main downsampling, request coalescing and synchronous recycled-cell hits. Audit lazy view/controller reuse. | Cache source/tests prepared; native execution pending |

Old midnight clips contain the previous daily-quota error. This is error-state
evidence; do not redeploy the backend based on those recordings. Later17:xxclips
show successful metadata/content and remain relevant for scrolling/interaction.

Next: finish all source changes and focused tests, self-review Swift6 isolation
and availability, then notify owner before starting the new candidate. Codemagic
remains the unreleased track; full same-source acceptance is needed for promotion.
No candidate is declared passed from source inspection or screenshots alone.
