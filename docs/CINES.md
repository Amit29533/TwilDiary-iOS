# Cines

Home → Cines: trailers and scenes from shows, movies and anime, one per screen, swiped up like reels (owner's request and drawing, 25 Nov 2026).

## Where the clips come from

The YouTube videos TMDB lists for each title (`{movie|tv}/{id}/videos`): trailers, teasers, clips, featurettes, openings and behind the scenes. These are mostly the official uploads from Netflix, Crunchyroll and the studios. For each title, the feed keeps its best trailer (or teaser) and its best clip, official uploads first. A title's second clip comes a few clips later, so the same title never plays twice in a row.

The titles behind each tab:

- **For you** (owner's request, 25 Nov 2026: a mix that looks random). Each round takes a few titles from each of these sources and shuffles them together:
  - **your diary:** titles you've planned, are watching or have watched (three a round);
  - **recommendations** from two titles you've watched lately, favourited or scored 8 or more;
  - **trending this week;**
  - **top rated:** only well-known titles, those with many votes;
  - **popular right now;**
  - **your genres:** popular titles in a genre you watch most (favourites count twice).

  Each source starts at a random page.
- **Shows:** TMDB's trending shows of the week, shuffled.
- **Movies:** TMDB's trending movies of the week, shuffled.
- **Anime:** Japanese animation by popularity, shows and films mixed, then shuffled.

Outside For you's diary picks, titles already in your diary go to the back, and only every second one is kept, so they come up less often. Code: `ios/App/Networking/CinesFeed.swift`.

## The official channels

TMDB lists mostly trailers, so Cines also reads the official YouTube channels themselves (owner's call, 25 Nov 2026, as the anime.com app does). Their public feeds need no key and have no quota. Each channel gives two feeds of about 15 videos each: its newest uploads and its newest Shorts. Code: `ios/App/Networking/CinesChannels.swift`.

- **The channels:**
  - **Shows and films:** Netflix, Netflix K-Content, Prime Video, Disney+, HBO, Apple TV, Hulu, Paramount+, Peacock, A24, Universal Pictures, Sony Pictures and Marvel.
  - **Anime:** Netflix Anime, Crunchyroll, Muse Asia, Aniplex USA, TOHO animation, GKIDS and KyoaniChannel (Kyoto Animation; its titles are in Japanese, so the name in 「」 is matched against TMDB's original titles).
- **How videos are read:** two channels at a time, in a random order, as the feed loads.
- **Matching a video to its title:** the video's title is read for names:
  - the parts between "|" ("Scene | Kakegurui | Clip | Netflix Anime" gives Kakegurui);
  - a Short's hashtags ("#BlueBox" gives Blue Box);
  - a name in capitals inside a sentence.

  Words like Clip and Trailer, and channel names, are dropped. "Season 3" and a trailing number are tried without.

  Each name is searched on TMDB. A video joins the feed only when TMDB has a title by that very name (or its best match is clearly the same), so Plan adds the right title. An anime channel's videos match anime only, and channel promos are left out.
- **Mixing:** up to four channel clips a round are mixed in with TMDB's, in every tab (each tab keeps its kind). A Short is vertical and fills the player's height.

The feeds hold only each channel's newest videos.

## With a YouTube key

TwilDiary's YouTube Data API key is built in the way the TMDB key is: `TWILDIARY_YOUTUBE_KEY` is filled from the repository secret of the same name when the IPA is built, and it's never in git. Your own key can be added instead on Settings → APIs → YouTube, where it's kept in the Keychain. Code: `ios/App/Networking/CinesYouTube.swift`.

With a key, Cines:

- **checks each batch of clips before they show** (1 unit for up to 50): whether YouTube lets them play in the app, whether they're public, and whether they're blocked in your country. Clips that fail never appear.
- **reads back through each channel's uploads and Shorts,** 50 at a time (1 unit a page), not just the newest 15. Channels with older videos left come round again.
- **searches YouTube for scenes** from one title in your diary each time For you loads more (Planned first). Each search costs 100 units, and there are at most 30 a day. A video is kept when its title names the show and it isn't a reaction, review, edit or the like; the official channels' come first.

The free quota is 10,000 units a day. When YouTube says it's used up, Cines carries on without the key until the next day.

## Playing

The clips play in YouTube's own embedded player (the IFrame API) in one web view that moves from page to page (`ios/App/Screens/CinesPlayer.swift`). It's set up the way YouTubePlayerKit 2.0.5 does it:

- the page is loaded at `https://<bundle id>`, and that address is given to the player as its `origin`;
- playback is inline, with no tap needed to start.

Nothing is downloaded or re-hosted.

The layout (owner's drawing, 25 Nov 2026):

- **A wide clip's** player fills the space from under the tabs down to the buttons, as the anime.com app's does. YouTube centres the video in it and puts its own title, seek bar and logo at its edges, not on the picture. The title's blurred picture is behind it, and the buttons on the right start below it, so nothing of ours covers it.
- **A Short** fills the screen. Its tabs, buttons and title show when it starts and fade after three seconds (owner's call: a personal app). A tap brings them back, and they stay while it's paused.
- **YouTube's normal controls,** as YouTubePlayerKit and youtube_player_iframe have them by default and as anime.com shows them: a clip that starts by itself plays clean, and a tap or a pause brings up YouTube's controls (time, seek bar, Share), which fade again by themselves. The "no controls" mode used before put a big pause button, Share and "More videos" over the start of every clip on a phone.

Each clip starts muted, and Sound turns the sound on. A clip loops at its end.

Only English videos are used; anime may also use Japanese ones, with English first. Before a clip comes on screen, YouTube's public oEmbed lookup is asked about it and the next few. A video whose uploader switched embedding off, or that was taken down, is dropped from the feed and left out from then on. If YouTube still refuses a clip while it plays (for example, a region block), the feed moves on to the next one.

## The buttons

On the right (`ios/App/Screens/CinesView.swift`):

- **Plan:** adds the title to Planned, the same way Search's + does. While the title is Planned, it shows a green tick, and a tap takes it back out (to Trash, after asking). A title you're watching or have watched shows its state instead.
- **Details:** opens the title's page.
- **Sound:** turns the sound on or off.
- **Share:** shares the YouTube link.

Bottom left: what the clip is, the title, "Show · year · genres", and the channel that posted it. At the top: back, then For you, Shows, Movies and Anime as plain text tabs.
