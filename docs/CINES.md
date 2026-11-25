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

## Playing

The clips play in YouTube's own embedded player (the IFrame API) in one web view that moves from page to page (`ios/App/Screens/CinesPlayer.swift`). It's set up the way YouTubePlayerKit 2.0.5 does it:

- the page is loaded at `https://<bundle id>`, and that address is given to the player as its `origin`;
- playback is inline, with no tap needed to start.

Nothing is downloaded or re-hosted.

YouTube's player gets the middle of the screen to itself, with its own title at the top and its logo at the bottom, and nothing of ours over it. This follows the anime.com app (owner's call, 25 Nov 2026, after the first layout's buttons covered the video). The title's blurred picture shows around the video.

Each clip starts muted, and Sound (top right) turns the sound on. A tap pauses, and a clip loops at its end.

Only English videos are used; anime may also use Japanese ones, with English first. Before a clip comes on screen, YouTube's public oEmbed lookup is asked about it and the next few. A video whose uploader switched embedding off, or that was taken down, is dropped from the feed and left out from then on. If YouTube still refuses a clip while it plays (for example, a region block), the feed moves on to the next one.

## The panel

Below the video (`ios/App/Screens/CinesView.swift`):

- what the clip is;
- the title, with a › that opens its page;
- "Show · year · genres";
- **Share:** shares the YouTube link;
- **Plan:** adds the title to Planned, the same way Search's + does. While the title is Planned, it shows a green **Planned**, and a tap takes it back out (to Trash, after asking). A title you're watching or have watched shows its state instead.
