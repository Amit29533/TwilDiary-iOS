# Saved clips

Share a reel, a video or a link to TwilDiary and it works out which movie or show it's from (owner's request, November 2026).

## Getting a clip in

- **Share sheet.** TwilDiary is in the share sheet of other apps (Instagram, TikTok, YouTube, Photos, Files, browsers). The extension (`ios/ShareExtension/ShareViewController.swift`, target `TwilDiaryShare`) only saves: a link, the text that came with it, or a copy of the video or picture. It shows a first guess when the caption names a title clearly (TMDB, with the key built into the app). It needs the app group `group.com.amit29533.TwilDiary` (`ios/Support/Share.entitlements`, and the app's `TwilDiary.entitlements`); CI signs the extension with it (`ios/scripts/ci.sh`, `package`). A sideloading tool may rename the group: the app and extension look for it under `ALTAppGroups` in Info.plist (AltStore, SideStore) and in the signing profile inside the app before the built-in name (`ClipStore.groups`). When the install has no group at all, the share sheet copies a link and its caption, and Search → Saved clips shows a one-tap Paste row while a copied link waits (the clipboard is only checked for a link, so iOS asks nothing until you tap Paste). A video can't be handed over that way; it's added from Photos.
- **Paste or Photos.** Search → Saved clips → the chevron: Paste takes a copied link (with any caption around it), From Photos takes a saved video or picture. These work on any install, app group or not.

## Naming it

Done in the app when it opens (and when Search or Saved clips appears), never in the share sheet: `ios/App/Networking/ClipInbox.swift`. Cheapest first:

1. **The words.** Quoted titles, a title before its year, hashtags (not tags like #fyp or #kdrama), and for TikTok and YouTube links the post's caption, account and thumbnail from their public oEmbed lookups. Any other link (an Instagram reel, a Threads or Facebook post, a web page) is read as its public page, signed out, as mymind reads a saved link (`ClipPage`): its Open Graph title and description, with the wrapper Instagram puts round a caption ("Sulpho on Instagram: \"…\"", "168K likes, 262 comments - sulpho.96 on …: \"…\"") taken off by `ClipText.unwrap`, the account and the picture. Each part of a caption is read for a title before its year ("\"Where it all began\" - My Sassy Girl (2001) | Edit" gives My Sassy Girl, 2001), and the year picks between titles of the same name (the 2001 film, not the 2008 remake). Each becomes a TMDB search (`ClipText`, `ClipTMDB` in `ios/ClipShared/SavedClip.swift`).
2. **The text on screen.** Four frames of a saved video (or the picture), read on the phone with Vision: title cards and credits.
3. **Gemini.** For every clip, while the words are searched on TMDB (as mymind reads every saved link with AI; owner's request, 25 Nov 2026), when Settings allows it (the switch in Profile → Connections → Identify clips with Gemini, `clips.gemini`): up to four frames, or a link's thumbnail, with the caption and the text on screen, sent to Gemini only (Groq and Requesty take text). Gemini names up to three titles with how sure it is; each is checked on TMDB.

The guesses merge (the same title found twice is surer) and the best three are kept (`ClipRanking`). A best guess at least 0.85 sure and 0.3 ahead of the next is taken as the title; otherwise the clip waits for you to pick.

## Using it

- **Search:** Saved clips, newest first, each saying where it stands (identified, pick the title, identifying, couldn't tell). A named clip opens its title; the others open the pick screen.
- **Pick the title:** the best three with posters and a match figure, or a TMDB search. Add to Planned, or just keep the clip with the title. Nothing enters the diary until you choose.
- **Title pages:** Your clips. A link opens the post where it came from; a saved video plays in TwilDiary.
- **Home:** "1 clip to pick" when a clip waits for you.

Clips are kept in `clips.json` and their files in the app group's `Clips` folder (or the app's own Application Support folder when there's no group). Tests: `ios/Tests/SavedClipsTests.swift`.
