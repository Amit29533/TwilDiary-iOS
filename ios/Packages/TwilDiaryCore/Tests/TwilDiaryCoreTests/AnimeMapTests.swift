import Foundation
import Testing
@testable import TwilDiaryCore

/// Slices of the real maps (anibridge-mappings and animeApi, 2026-11-15): Re:Zero as TMDB numbers
/// it now (one season, 1-85; its specials in season 0), Angel Beats!' specials, Bisque Doll (the
/// map gives season 2's entry for TMDB's season 1), a split range and a ratio (left out), a film,
/// and animeApi's rows.
private let mappings = Data(#"""
{"$meta":{"schema_version":"3.0.3"},
 "tmdb_show:65942:s1":{"anilist:21355":{"1-25":"1-25"},"anilist:108632":{"26-38":"1-13"},"anilist:119661":{"39-50":"1-12"},"anilist:163134":{"51-66":"1-16"},"mal:31240":{"1-25":"1-25"}},
 "tmdb_show:65942:s0":{"anilist:21780":{"1-11":"1-11"},"anilist:21891":{"12-25":"1-14"}},
 "tmdb_show:42942:s1":{"anilist:6547":{"1-13":"1-13"}},
 "tmdb_show:42942:s0":{"anilist:10067":{"3":"1"}},
 "tmdb_show:123249:s1":{"anilist:154768":{"1-12":"1-12"}},
 "tmdb_show:500:s1":{"anilist:1003":{"1-12":"1-6,8-13","13-":"14-|2"}},
 "tmdb_movie:372058":{"anilist:21519":{"1":"1"},"mal:32281":{"1":"1"}},
 "anilist:21355":{"tmdb_show:65942:s1":{"1-25":"1-25"}}}
"""#.utf8)
private let animeApi = Data("""
title\tanidb\tanilist\tsimkl\tthemoviedb\tthemoviedb_type
Re:Zero\t11370\t21355\t509292\t65942\ttv
Re:Zero 2nd Season\t14792\t108632\t1063491\t65942\ttv
Angel Beats!\t6564\t6547\t38481\t42942\ttv
ViVid Strike!\t12264\t21871\t612999\t68096\ttv
Kimi no Na wa.\t11829\t21519\t543146\t372058\tmovie
No Simkl\t1\t2\t\t3\ttv
""".utf8)
private func pair(_ value: (id: Int, episode: Int)?) -> [Int]? { value.map { [$0.id, $0.episode] } }
private func pair(_ value: (season: Int, number: Int)?) -> [Int]? { value.map { [$0.season, $0.number] } }
private func built() throws -> AnimeMap { try AnimeMap.build(mappings: mappings, animeApi: animeApi, builtAt: "2026-11-15T08:42:10Z") }

@Test func theMapNamesEachTMDBEpisodesAniListEntryAndEpisode() throws {
    let map = try built()
    #expect(pair(map.anilist(tmdb: 65942, season: 1, episode: 1)) == [21355, 1])
    #expect(pair(map.anilist(tmdb: 65942, season: 1, episode: 26)) == [108632, 1])
    #expect(pair(map.anilist(tmdb: 65942, season: 1, episode: 39)) == [119661, 1], "part 2's first episode")
    #expect(map.anilist(tmdb: 65942, season: 2, episode: 1) == nil, "TMDB no longer has a season 2: the matching decides")
    #expect(pair(map.anilist(tmdb: 42942, season: 0, episode: 3)) == [10067, 1], "Another Epilogue")
    #expect(map.anilist(tmdb: 42942, season: 0, episode: 2) == nil, "Stairway to Heaven isn't in the map")
    #expect(map.anilist(tmdb: 500, season: 1, episode: 3) == nil, "a split range or a ratio is left out")
    #expect(map.anilistEntries(tmdb: 65942) == [21355, 108632, 119661, 163134, 21780, 21891], "seasons first, specials after")
    #expect(map.anilistFilm(tmdb: 372058) == 21519)
    #expect(pair(map.tmdbEpisode(tmdb: 65942, anilist: 108632, episode: 13)) == [1, 38])
    #expect(pair(map.tmdbEpisode(tmdb: 42942, anilist: 10067, episode: 1)) == [0, 3])
    #expect(map.tmdbEpisode(tmdb: 65942, anilist: 108632, episode: 14) == nil)
}
@Test func theMapGivesSimklEntries() throws {
    let map = try built()
    #expect(map.simkl(tmdb: 65942, film: false) == 509292, "a show: its first episode's entry")
    #expect(map.simkl(anilist: 108632) == 1063491, "Re:Zero's second cour, as Simkl's own placing found it")
    #expect(map.simkl(tmdb: 68096, film: false) == 612999, "ViVid Strike!: Simkl lists it with no TMDB id")
    #expect(map.simkl(tmdb: 372058, film: true) == 543146)
    #expect(map.simklShows["65942"] == nil, "two Simkl entries for one TMDB show: none by the show")
    #expect(map.simkl(tmdb: 3, film: false) == nil)
    let again = try JSONDecoder().decode(AnimeMap.self, from: JSONEncoder().encode(map))
    #expect(again == map)
}
@Test func airDatesCatchTheMapsMistakes() {
    // Bisque Doll: TMDB's S1 E1 (2022-01-09) given season 2's entry (2025-07-06).
    #expect(!AnimeMap.plausible(day: "2022-01-09", start: "2025-07-06", end: "2025-09-21"))
    #expect(AnimeMap.plausible(day: "2025-07-06", start: "2025-07-06", end: "2025-09-21"))
    #expect(AnimeMap.plausible(day: "2010-12-22", start: "2010-12-22", end: nil), "a special dated by its release")
    #expect(AnimeMap.plausible(day: "2020-06-20", start: "2020-07-08", end: "2020-09-30"), "within 30 days: an early screening")
    #expect(!AnimeMap.plausible(day: "2020-11-30", start: "2020-07-08", end: "2020-09-30"))
    #expect(AnimeMap.plausible(day: nil, start: "2020-07-08", end: nil), "no day: nothing contradicts it")
}

@Test func theMapPlacesEpisodesAndSpecialsTheDatesCant() {
    let chain = [AniListPlan.Media(id: 6547, format: "TV", episodes: 13, start: "2010-04-03", end: "2010-06-26"),
                 AniListPlan.Media(id: 10067, format: "SPECIAL", episodes: 1, start: "2010-12-22", end: "2010-12-22")]
    let watches = (1...13).map { AniListPlan.Watch(season: 1, number: $0, aired: nil, watchedAt: "2021-04-07T12:04:00Z") }
        + [AniListPlan.Watch(season: 0, number: 3, aired: "2010-12-22", watchedAt: "2024-11-20T18:30:00Z"),
           AniListPlan.Watch(season: 0, number: 2, aired: "2010-12-22", watchedAt: "2024-11-20T18:30:00Z")]
    let without = AniListPlan.entries(status: "completed", score: 8, film: false, watches: watches, chain: chain)
    #expect(without.entries.map(\.mediaId) == [6547], "specials aren't sent without the map, and the special entry takes no episode by date")
    #expect(without.entries[0].progress == 13 && without.unplaced == 0)
    let with = AniListPlan.entries(status: "completed", score: 8, film: false, watches: watches, chain: chain, placed: ["0x3": 10067])
    #expect(with.entries.map(\.mediaId) == [6547, 10067])
    #expect(with.entries[1].status == "COMPLETED" && with.entries[1].progress == 1)
}
@Test func theMapNamesAniListsEpisodesForTheDiary() throws {
    let map = try built()
    let chain = [AniListPlan.Media(id: 21355, format: "TV", episodes: 25, start: "2016-04-04", end: "2016-09-19"),
                 AniListPlan.Media(id: 108632, format: "TV", episodes: 13, start: "2020-07-08", end: "2020-09-30")]
    let watches = (1...30).map { AniListPlan.Watch(season: 1, number: $0, aired: nil, watchedAt: "2021-04-07T12:04:00Z") }
    let listed = [AniListPlan.ListedDetail(mediaId: 108632, status: "CURRENT", progress: 9, score: nil, notes: nil, updatedAt: "2026-11-14T20:30:00Z")]
    let adoption = AniListPlan.adoption(diaryStatus: "watching", diaryScore: nil, diaryNotes: "", film: false, watches: watches,
                                        chain: chain, listed: listed, seasons: [:], map: map, tmdb: 65942)
    #expect(adoption.episodes.map(\.number) == [31, 32, 33, 34], "part 1's episode 9 is TMDB's S1 E34")
    #expect(adoption.unplaced == 0)
}

@Test func whatNeverLandsIsIgnoredForGoodAfterThreeSends() {
    var stop = RetryStop()
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    for round in 1...3 {
        stop.sent(["play|tv:42942|s0e2", "play|tv:1|s1e1"])
        #expect(stop.observe(missing: ["play|tv:42942|s0e2"], now: day) == (round == 3 ? ["play|tv:42942|s0e2"] : []))
    }
    #expect(stop.isParked("play|tv:42942|s0e2"))
    #expect(stop.tries["play|tv:1|s1e1"] == nil, "it landed: forgotten")
    #expect(stop.observe(missing: [], now: day.addingTimeInterval(400 * 86_400)).isEmpty)
    #expect(stop.isParked("play|tv:42942|s0e2"), "ignored for good: it doesn't come back")
    // AniList's keys carry the state: a later watch is a new key, sent and checked as usual.
    stop.sent(["frieren|154587:CURRENT:5:0"]); stop.sent(["frieren|154587:CURRENT:5:0"]); stop.sent(["frieren|154587:CURRENT:5:0"])
    stop.observe(missing: ["frieren|154587:CURRENT:5:0"], now: day)
    #expect(stop.isParked("frieren|154587:CURRENT:5:0") && !stop.isParked("frieren|154587:CURRENT:6:0"))
}
