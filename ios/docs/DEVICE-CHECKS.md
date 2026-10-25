# Current physical-device verification boundary

Native61 has a verified complete Codemagic pass and unsigned IPA. Its automated
checks do not certify physical frame pacing, glass composition, haptics, battery,
VoiceOver or the largest accessibility type. Current checks for that IPA:

- Slowly reverse-scroll saved/online titles through the compact-header fade;
  check centered identity and a single usable Share/Information action.
- Hold/slide/cancel the official native tab bar and swipe all root tabs in both
  directions; short Glance swipes must log one watch and preserve Undo ownership.
- Check Information translucency at medium/large detents while scrolling; dark
  sentiment cards should remain readable with Reduce Transparency toggled.
- Cold-launch offline, reconnect, sign out during a read, then change account;
  old protected content must never appear under the new session.
- Exercise large text/VoiceOver through episode grids, history, filters, Undo and
  import Pause. Assess scrolling and battery with a large real library.

63cold-quota bootstrap and62privacy/database/workflow changes are separate
candidates; do not test/claim them as native61 features. The older checklist below
records build-specific history and is superseded where behavior has changed.

# Real-device checks

After each passed build, install the unsigned IPA using LiveContainer or your signing tool and check:

- Cloudflare sign-in including 2FA, app relaunch and expired-session recovery.
- Safe areas and keyboard dismissal on the actual phone.
- Glance swipe release logs exactly one watch and preserves scroll position; Undo restores it.
- Home carousel and Library scroll smoothness with a large library.
- Remaining-time contrast over bright art and Liquid Glass readability.
- Native menu presentation, tap highlight release and theme switching.
- Haptics and animation timing require physical-device evaluation and are not established by CI screenshots.
- Trakt auth-only browser: direct sign-in, server callback, expired Access session and cancellation. For identity providers that reject embedded browsers, use Connect in browser and confirm that returning to the app refreshes the connection.
- Cold-launch the saved diary with networking unavailable, then reconnect. Confirm the saved-copy notice and the server refresh, and verify that signing out removes the cached diary.
- Drag a series track across several episode counts, change seasons quickly, log a past-date movie rewatch, and Undo while the content stays in place. Simulator pixels and mock transport coverage do not prove physical gesture timing.

Hosted mutation tests require the owner's explicit authorization. Simulator checks use synthetic fixtures.

- Random pick: three logo taps within 850ms open one dialog; ordinary spaced taps only spin the logo. Check the 650ms reroll guard, reduced-motion behavior, VoiceOver modal focus/escape and keyboard dismissal. CI screenshots cannot establish those physical timings.

- Confirmed save with a subsequent read outage: after the write receipt, disconnect networking before refresh completes. The Saved/Refresh notice must preserve the old complete diary and Undo, disable repeated writes, then clear after reconnect/Refresh shows exactly one added viewing. Check app interruption/relaunch separately; recovery markers are currently session memory, not a persisted write outbox.

## Build 24 device feedback follow-up (pending CI and phone validation)

- Time Undo toast expiry after single/repeated actions and VoiceOver; ensure refresh recovery keeps its actionable receipt visible.
- On a slow connection, verify only the tapped card spins/dims, other cards can queue an action, and interrupted writes never silently duplicate a watch.
- Swipe back from Explore/search/title anywhere outside an actively dragged episode control. Confirm the slider still adjusts without navigating and search returns immediately without showing Home first.
- Check real Trakt public ratings with the existing hosted configuration; fixture/network timeout tests cannot establish provider uptime or missing server credentials. No backend deploy is authorized.
- Review native glass contrast, short press/card springs, selection haptics, Reduce Motion and Reduce Transparency on the physical iPhone; no simulated smoothness/battery claim.

## Scroll artwork and scrub navigation follow-up

- Verify hero art remains full bleed at the top and scrolls completely out before lower episode/notes content; check saved titles, online previews and person pages.
- Hold Library and slide through all five tabs; the lens should follow the finger, with one final destination on release. Release above/outside the bar to cancel; normal active-tab taps should still return to the tab root. Test VoiceOver activation, Reduce Motion, all six themes and a phone with a Home indicator.
- The scrub lens uses one shared native glass bar plus light/shape feedback rather than an extra live image blur per tab. Physical spring, haptic and touch comfort require real-phone validation.


## Device-feedback build 29 (pending simulator and phone verification)

- Confirm saved and online hero artwork reaches behind the status/navigation bars; it scrolls away into black without showing through episode/Notes rows.
- Expand More: the opening two lines remain beside the cover, only overflow continues beneath. Check a long synopsis, emoji and the largest text setting.
- From Home, cast filmography and More subpages, Done must return exactly one level. Test both a completed swipe and a short cancelled swipe. Online search must retain the query with no keyboard behind the transitioning title.
- From Glance → Notes, wait for cast/related metadata: the editor stays visible until a finger scroll or editor focus takes control. Save, back and reopen to verify persistence.
- Surprise backdrop tap stays open. Swipe up/down/left/right dismisses; a short drag springs back; Close and VoiceOver Escape work. VoiceOver must reach the heading, reroll and Open actions without reaching the dimmed app.
- Test collection grid/list preferences, scroll and independent +/- actions in Glance. Confirm a layout change retains data and does not block unrelated cards. Review narrow-phone long paths and Trakt conflict actions in grid mode.
- Assess spring motion, haptics and scroll responsiveness on the actual phone, including Reduce Motion/Reduce Transparency. CI screenshots do not establish physical smoothness.


## Latest hero/native navigation/Glass checks — prepared build35

- Latest feedback supersedes the earlier beside-cover opening synopsis check: inspect lowered name/ratings over darkened artwork and full-width synopsis beneath. More must keep the opening copy stationary, add only overflow, and never lose words/emoji.
- Scroll saved and online long titles into compact poster/name/Back/Share and back; verify top art bleed, contrast over bright artwork, no title clipping/jump and native cancelled/completed Back.
- Pushed History/Files/Appearance/Scanner/TMDB/Trakt/About and Explore use native Back/content swipe. Done is retained only for modal editing. Re-enter each and check query/scroll restoration and slider gesture protection.
- In Glass, assess the blurred artwork/dominant backdrop through panels and the bottom navigation bar, all five hold/slide/release targets, Reduce Motion/Transparency and a large library. Screenshots cannot prove physical stutter, haptics or battery performance.

## Access recovery and native transition checks — prepared build38

- Perform the real Cloudflare login/2FA without rushing. Cancel during login and immediately reopen; a late callback from the cancelled browser must not reconnect or close the new browser.
- After a network failure or WebKit process interruption, the inline Try again action should create a fresh ephemeral sign-in page; normal redirect cancellations must not show an error. Verify delayed cookie completion and missing-cookie retry without shortening the person's 2FA time.
- Confirm an existing installation retains secure Keychain access after the policy update, and genuine server validation still precedes credential persistence. No Access/binding-cookie configuration is changed automatically.
- Reselect Home from Explore and let the native transition settle. Reopen and complete/cancel content Back; query/scroll ownership and slider protection remain intact. A transition-time accessibility node is not a completed-navigation failure.


## Incoming watches (prepared native40, backend deployment pending approval)

- After approved setup, record one completed episode in Trakt; measure time from its appearance in Trakt to scheduled D1 import, then iOS open/resume. The upstream player is outside this scope. Verify progress without relaunching or pulling to refresh.
- Repeat on a cold title/season, expired OAuth refresh and a provider cooldown. Check Cloudflare idle/watch/refresh/metadata CPU against the Free10ms limit and actual D1 row metrics before claiming a one-minute guarantee.
- Toggle off/disconnect while an import is in flight; verify no late writes. Review manual sync while incoming is enabled and see its paused state. Undo a play/Trash/purge a title and confirm polling does not revive it.
- Briefly interrupt with Control Center or switch apps during a write; verify no duplicate play, draft loss, keyboard jump or blocked resume. Repeated rapid scene changes must not issue full refresh loops.

## Performance and packaged resources — prepared native41

- With a large real library, compare cold launch/resume and warm Home/Stats/theme/tab changes. Workspace JSON now decodes outside the main actor, but cold projection and protected cache work still need profiling; CI benchmark timings do not establish real-phone frame rate or battery cost.
- Sign out during a large read and immediately reconnect. Old decoded pages must never appear in the new session. Interrupt a resume repeatedly and verify the next genuine resume still refreshes.
- Install the unsigned Release through the owner's chosen container/signing route. Confirm it uses authenticated live APIs and genuine demo artwork as appropriate; disposable simulator fixture JSON must be absent under the CI package gate.

## Owner results — 25 October 2026, native build40

- Owner reports genuine Information sentiment content and swipe-down dismissal work.
- Incoming-watch setting turns on and remains on after multiple full app restarts.
- Glance Notes opens at the actual editor.

These are owner-reported real-phone results, not simulator screenshots or full-release acceptance. Next checks: caught-up Trakt watch import/duplicate prevention and delay, episode/range/movie Undo, season boundaries, keyboard/cancelled Back, long synopsis/compact header, offline recovery, Trash restore and navigation-lens gestures.

### Owner feedback batch44 (pending new IPA)

Build40 owner confirms sentiment swipe-down, incoming setting persistence, Glance Notes targeting, watch/Undo/current-season actions, keyboard-safe Back, navigation scrub and offline. New44 needs real-phone verification: slow/reversing scroll across title-header threshold (no stutter, centred identity); push and complete/cancel content Back (bar travels with page, no delayed pop-in); root right-next/left-previous swipes versus horizontal shelves/Glance watch-card swipes/nav scrub/sliders; static initial loading and unchanged content during refresh; Information medium/large/scroll transparency with dark sentiment cards; expanded episode grids without vertical holes; recommendations/cast layout switch at the heading. Simulator passes cannot prove frame pacing/haptics/material rendering on the owner's phone.
