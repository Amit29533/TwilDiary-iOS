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

Each clip starts muted, and Sound turns the sound on. A tap pauses. A clip loops at its end. If YouTube refuses a clip (for example, the uploader switched embedding off), the page offers "Watch on YouTube", and that clip is left out from then on. The channel name under the title comes from YouTube's public oEmbed.

## The buttons

`ios/App/Screens/CinesView.swift`:

- **Plan:** adds the title to Planned, the same way Search's + does. While the title is Planned, it shows a green tick, and a tap takes it back out (to Trash, after asking). A title you're watching or have watched shows its state instead.
- **Details:** opens the title's page.
- **Sound:** turns the sound on or off.
- **Share:** shares the YouTube link.
