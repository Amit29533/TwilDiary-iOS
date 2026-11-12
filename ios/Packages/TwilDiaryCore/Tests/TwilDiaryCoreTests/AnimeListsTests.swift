import Foundation
import Testing
@testable import TwilDiaryCore

/// A few entries in anime-list-master.xml's own shape: Attack on Titan's seasons on one TVDB/TMDB
/// show (season 3 split in two cours, the second starting at episode 13), an OVA filed as special 5,
/// and Rizelmine, numbered absolutely and mapped episode by episode.
private let sample = Data("""
<?xml version="1.0" encoding="utf-8"?>
<anime-list>
  <anime anidbid="9541" tvdbid="267440" defaulttvdbseason="1" episodeoffset="" tmdbtv="1429" tmdbseason="1" tmdboffset="" tmdbid="" imdbid=""><name>Shingeki no Kyojin</name></anime>
  <anime anidbid="10944" tvdbid="267440" defaulttvdbseason="2" episodeoffset="" tmdbtv="1429" tmdbseason="2" tmdboffset="" tmdbid="" imdbid=""><name>Shingeki no Kyojin (2017)</name></anime>
  <anime anidbid="13241" tvdbid="267440" defaulttvdbseason="3" episodeoffset="" tmdbtv="1429" tmdbseason="3" tmdboffset="" tmdbid="" imdbid=""><name>Shingeki no Kyojin (2018)</name></anime>
  <anime anidbid="14444" tvdbid="267440" defaulttvdbseason="3" episodeoffset="12" tmdbtv="1429" tmdbseason="3" tmdboffset="12" tmdbid="" imdbid=""><name>Shingeki no Kyojin (2019)</name></anime>
  <anime anidbid="9970" tvdbid="267440" defaulttvdbseason="0" episodeoffset="4" tmdbtv="1429" tmdbseason="0" tmdboffset="4" tmdbid="" imdbid=""><name>Shingeki no Kyojin OVA</name></anime>
  <anime anidbid="19" tvdbid="83692" defaulttvdbseason="a" episodeoffset="" tmdbtv="34684" tmdbseason="a" tmdboffset="" tmdbid="" imdbid="">
    <name>Rizelmine</name>
    <mapping-list>
      <mapping anidbseason="1" tvdbseason="1" start="1" end="12"/>
      <mapping anidbseason="1" tvdbseason="2" start="13" end="24" offset="-12"/>
      <mapping anidbseason="0" tvdbseason="0">;1-4;</mapping>
    </mapping-list>
  </anime>
  <anime anidbid="77" tvdbid="" defaulttvdbseason="" episodeoffset="" tmdbtv="" tmdbseason="" tmdboffset="" tmdbid="" imdbid=""><name>No links</name></anime>
</anime-list>
""".utf8)

@Test func animeListsPlaceTheDiarysEpisodesOnTheirAniDBEntries() throws {
    let index = AnimeListIndex.parse(sample)
    #expect(index.byAniDB.count == 7)
    func at(_ season: Int, _ episode: Int) -> String? {
        index.anidb(tmdb: 1429, tvdb: 267440, season: season, episode: episode).map { "\($0.anidb)#\($0.episode)" }
    }
    #expect(at(2, 4) == "10944#4")
    #expect(at(3, 5) == "13241#5", "the first cour of a split season")
    #expect(at(3, 15) == "14444#3", "the second cour starts at episode 13")
    #expect(at(0, 5) == "9970#1", "a special filed as its own AniDB entry")
    #expect(at(0, 2) == nil, "a special no entry holds")
    // Numbered absolutely and mapped episode by episode: TVDB's season 2 episode 3 is AniDB's 15.
    let rizelmine = index.anidb(tmdb: 34684, tvdb: 83692, season: 2, episode: 3)
    #expect(rizelmine?.anidb == 19 && rizelmine?.episode == 15)
    // Back: an AniDB entry's own episode as the show's season and episode.
    let back = try #require(index.show(anidb: 14444, episode: 3))
    #expect(back.tmdb == 1429 && back.season == 3 && back.episode == 15)
    let mapped = try #require(index.show(anidb: 19, episode: 15))
    #expect(mapped.tvdb == 83692 && mapped.season == 2 && mapped.episode == 3)
    #expect(index.show(anidb: 77, episode: 1) == nil)
}

@Test func simklsNotFoundEpisodesAreSentAgainByAniDBEntryAndMerged() throws {
    let index = AnimeListIndex.parse(sample)
    let sent = Data(#"{"shows":[{"ids":{"tmdb":1429,"tvdb":267440},"seasons":[{"number":3,"episodes":[{"number":15,"watched_at":"2021-01-01T00:00:00Z"},{"number":16,"watched_at":"2021-01-02T00:00:00Z"}]},{"number":0,"episodes":[{"number":2,"watched_at":"2021-01-03T00:00:00Z"}]}]}]}"#.utf8)
    let reply = Data(#"{"added":{"episodes":0},"not_found":{"movies":[],"shows":[],"episodes":[{"ids":{"tmdb":1429,"tvdb":267440},"seasons":[{"number":3,"episodes":[{"number":15},{"number":16}]},{"number":0,"episodes":[{"number":2}]}]}]}}"#.utf8)
    let retry = try #require(SimklAnimeFallback.retry(sent: sent, reply: reply, index: index))
    let body = try #require(try JSONSerialization.jsonObject(with: retry.body) as? [String: Any])
    let anime = try #require(body["anime"] as? [[String: Any]])
    #expect(anime.count == 1)
    #expect((anime[0]["ids"] as? [String: Any])?["anidb"] as? Int == 14444)
    let episodes = try #require(anime[0]["episodes"] as? [[String: Any]])
    #expect(episodes.map { $0["number"] as? Int } == [3, 4])
    #expect(episodes.first?["watched_at"] as? String == "2021-01-01T00:00:00Z")
    #expect(retry.placed.count == 2, "special 2 has no AniDB entry, so it isn't resent")

    // Simkl took both: they leave the not-found list and count as added; special 2 stays.
    let merged = SimklAnimeFallback.merge(reply: reply, retry: retry, retryReply: Data(#"{"added":{"episodes":2},"not_found":{"anime":[]}}"#.utf8))
    let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
    #expect((root["added"] as? [String: Any])?["episodes"] as? Int == 2)
    let left = try #require((root["not_found"] as? [String: Any])?["episodes"] as? [[String: Any]])
    let seasons = left.first?["seasons"] as? [[String: Any]]
    #expect(seasons?.count == 1 && seasons?.first?["number"] as? Int == 0)

    // Simkl missed the entry again: the first answer stands.
    let missed = SimklAnimeFallback.merge(reply: reply, retry: retry,
                                          retryReply: Data(#"{"added":{"episodes":0},"not_found":{"anime":[{"ids":{"anidb":14444}}]}}"#.utf8))
    #expect(missed == reply)
}

@Test func simklEpisodesWithoutATVDBPlaceAreReadOntoTheDiarysShow() throws {
    let index = AnimeListIndex.parse(sample)
    // The second cour as Simkl files it: its own entry and TMDB id, episodes from 1, no TVDB block.
    let library = try TrackerDecode.simklLibrary(from: Data("""
    {"anime":[{"show":{"title":"Shingeki no Kyojin Season 3 Part 2","ids":{"simkl":1066341,"tmdb":"274822","anidb":"14444"}},"anime_type":"tv",
               "seasons":[{"number":1,"episodes":[{"number":3,"watched_at":"2021-01-01T00:00:00Z"}]}]},
              {"show":{"title":"Unmapped","ids":{"simkl":5,"tmdb":"500","anidb":"99999"}},"anime_type":"tv",
               "seasons":[{"number":1,"episodes":[{"number":2}]}]}]}
    """.utf8), anime: index)
    let placed = try #require(library.plays.first { $0.title.simklId == 1066341 })
    #expect(placed.title.tmdbId == 1429 && placed.season == 3 && placed.episode == 15, "on the diary's show, at TMDB's numbers")
    let unmapped = try #require(library.plays.first { $0.title.simklId == 5 })
    #expect(unmapped.title.tmdbId == 500 && unmapped.season == 1 && unmapped.episode == 2, "nothing to place it by: as Simkl numbers it")
    // Without Anime-Lists, as before.
    let plain = try TrackerDecode.simklLibrary(from: Data(#"{"anime":[{"show":{"title":"x","ids":{"simkl":1066341,"tmdb":"274822","anidb":"14444"}},"seasons":[{"number":1,"episodes":[{"number":3}]}]}]}"#.utf8))
    #expect(plain.plays.first?.title.tmdbId == 274822 && plain.plays.first?.episode == 3)
}
