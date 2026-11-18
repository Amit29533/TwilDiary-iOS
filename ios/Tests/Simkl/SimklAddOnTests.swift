import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Simkl's sync: its copy queue, the bodies it sends, how it reads Simkl's answers, sign-in, and
/// that Simkl is kept in step but never the main tracker.
final class SimklAddOnTests: XCTestCase {
    private func watch(_ number: Int, season: Int = 1, at time: String = "2026-11-14T20:00:00.000Z", tmdb: Int = 1429) -> SimklJob {
        SimklJob(kind: .watch, tmdb: tmdb, movie: false, anime: true, name: "Attack on Titan", year: 2013, season: season, number: number, airedOn: "2013-04-07", watchedAt: time)
    }

    // MARK: Queue

    func testUnwatchCancelsAWatchThatHasntGoneAndTheReverse() {
        var queue = SimklQueue()
        queue.add(watch(1))
        var undo = watch(1); undo.kind = .unwatch
        queue.add(undo)
        XCTAssertTrue(queue.jobs.isEmpty, "watched then unwatched sends nothing")

        queue.add(undo)
        queue.add(watch(1))
        XCTAssertTrue(queue.jobs.isEmpty, "unwatched then watched again sends nothing")
    }

    func testATriedWatchIsntCancelled() {
        var queue = SimklQueue()
        var tried = watch(1); tried.attempts = 1; tried.lastError = "timed out"
        queue.add(tried)
        var undo = watch(1); undo.kind = .unwatch
        queue.add(undo)
        XCTAssertEqual(queue.jobs.map(\.kind), [.watch, .unwatch], "it may already be on Simkl, so the removal still goes")
    }

    func testANewerRatingOrListReplacesTheOlderOne() {
        var queue = SimklQueue()
        var rate = SimklJob(kind: .rate, tmdb: 550, movie: true, name: "Fight Club", rating: 7)
        queue.add(rate)
        rate.id = UUID().uuidString; rate.rating = 9
        queue.add(rate)
        var unrate = rate; unrate.id = UUID().uuidString; unrate.kind = .unrate
        queue.add(unrate)
        XCTAssertEqual(queue.jobs.map(\.kind), [.unrate])
        var plan = SimklJob(kind: .list, tmdb: 550, movie: true, name: "Fight Club", list: "plantowatch")
        queue.add(plan)
        plan.id = UUID().uuidString; plan.list = "completed"
        queue.add(plan)
        XCTAssertEqual(queue.jobs.filter { $0.kind == .list }.map(\.list), ["completed"])
    }

    func testEpisodesOfOneShowGoTogetherInOrderAndAWaitingTitleHoldsOnlyItself() {
        var queue = SimklQueue()
        queue.add(watch(1)); queue.add(watch(2))
        queue.add(SimklJob(kind: .rate, tmdb: 1429, movie: false, name: "Attack on Titan", rating: 9))
        queue.add(watch(3))
        queue.add(SimklJob(kind: .watch, tmdb: 550, movie: true, name: "Fight Club", watchedAt: "2026-11-14T21:00:00.000Z"))
        let now = Date()
        XCTAssertEqual(queue.batch(now: now).map(\.label), ["Attack on Titan · S1 E1", "Attack on Titan · S1 E2", "Fight Club"],
                       "several titles in one request; the rating in between keeps episode 3 for later")

        queue.jobs[0].notBefore = now.addingTimeInterval(60)
        XCTAssertEqual(queue.batch(now: now).map(\.name), ["Fight Club"], "the waiting show holds its own jobs, not the movie")
        XCTAssertEqual(queue.nextWake, now.addingTimeInterval(60))
    }

    // MARK: Bodies and answers

    func testShowBodyHasTvdbSeasonsForAnimeAndEachWatchTime() throws {
        let body = SimklBody.body([watch(1), watch(2), watch(1, season: 2)], simkl: 39687)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let show = try XCTUnwrap((root["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual(show["use_tvdb_anime_seasons"] as? Bool, true)
        XCTAssertEqual((show["ids"] as? [String: Any])?["simkl"] as? Int, 39687)
        XCTAssertEqual((show["ids"] as? [String: Any])?["tmdb"] as? Int, 1429)
        let seasons = try XCTUnwrap(show["seasons"] as? [[String: Any]])
        XCTAssertEqual(seasons.map { $0["number"] as? Int }, [1, 2])
        XCTAssertEqual((seasons[0]["episodes"] as? [[String: Any]])?.compactMap { $0["number"] as? Int }, [1, 2])
        XCTAssertEqual((seasons[0]["episodes"] as? [[String: Any]])?.first?["watched_at"] as? String, "2026-11-14T20:00:00.000Z")

        var own = watch(5); own.ownNumbering = true
        let ownShow = try XCTUnwrap(((JSONSerialization.jsonObject(with: SimklBody.body([own], simkl: 1)) as? [String: Any])?["shows"] as? [[String: Any]])?.first)
        XCTAssertNil(ownShow["use_tvdb_anime_seasons"], "an episode placed in Simkl's own numbering isn't sent as TVDB's")
    }

    func testRemovalsRatingsAndListsUseTheirOwnRoutesAndShapes() throws {
        var undo = watch(1); undo.kind = .unwatch
        XCTAssertEqual(SimklBody.path(.unwatch), "/sync/history/remove")
        let removal = try XCTUnwrap(((JSONSerialization.jsonObject(with: SimklBody.body([undo], simkl: nil)) as? [String: Any])?["shows"] as? [[String: Any]])?.first)
        XCTAssertNil(((removal["seasons"] as? [[String: Any]])?.first?["episodes"] as? [[String: Any]])?.first?["watched_at"], "a removal names the episode only")
        let movie = SimklJob(kind: .list, tmdb: 550, movie: true, name: "Fight Club", year: 1999, list: "plantowatch")
        let item = try XCTUnwrap(((JSONSerialization.jsonObject(with: SimklBody.body([movie], simkl: 2)) as? [String: Any])?["movies"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["to"] as? String, "plantowatch")
        XCTAssertEqual(item["year"] as? Int, 1999)
        XCTAssertEqual(SimklBody.path(.list), "/sync/add-to-list")
        XCTAssertEqual(SimklBody.path(.rate), "/sync/ratings")
    }

    func testNotFoundAnswers() {
        let jobs = [watch(1), watch(2)]
        XCTAssertEqual(SimklBody.notFound(Data(#"{"added":{"episodes":2},"not_found":{"movies":[],"shows":[],"episodes":[]}}"#.utf8), sent: jobs), [])
        XCTAssertEqual(SimklBody.notFound(Data(#"{"added":{"episodes":0},"not_found":{"shows":[{"ids":{"tmdb":1429}}]}}"#.utf8), sent: jobs), Set(jobs.map(\.id)))
        XCTAssertEqual(SimklBody.notFound(Data(#"{"not_found":{"episodes":[{"season":1,"number":2}]}}"#.utf8), sent: jobs), [jobs[1].id])
        XCTAssertEqual(SimklBody.notFound(Data(#"{"not_found":{"episodes":[{"something":"else"}]}}"#.utf8), sent: jobs), Set(jobs.map(\.id)),
                       "episodes named in a form TwilDiary doesn't read: all of them are tried by date")
    }

    func testAnEpisodeIsPlacedByItsAirDate() {
        let list = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"episode","date":"2013-04-07T00:00:00-05:00","tvdb":{"season":1,"episode":1}},
         {"episode":26,"type":"episode","date":"2013-09-28T00:00:00-05:00"},
         {"episode":1,"type":"special","date":"2013-12-09T00:00:00-05:00"}]
        """#.utf8))
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(SimklBody.find(day: "2013-04-08", in: list)?.number, 1, "a day off (time zones)")
        XCTAssertEqual(SimklBody.find(day: "2013-09-28", in: list)?.number, 26)
        XCTAssertEqual(SimklBody.find(day: "2013-12-09", in: list, special: true)?.special, true, "a special")
        XCTAssertNil(SimklBody.find(day: "2013-12-09", in: list), "a regular episode never lands on a special")
        XCTAssertNil(SimklBody.find(day: "2013-04-07", in: list, special: true, anyKind: false), "in a show's own entry a special matches only a special")
        XCTAssertEqual(SimklBody.find(day: "2013-04-07", in: list, special: true)?.number, 1, "an OVA entry lists its parts as regular episodes")
        XCTAssertNil(SimklBody.find(day: "2014-01-01", in: list))

        // Re:Zero's third season on Simkl: episode 1 dated by its early screening, a special on the
        // TV premiere day (TMDB's date for S1 E51).
        let third = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"episode","date":"2024-08-30T00:00:00+09:00"},
         {"episode":2,"type":"episode","date":"2024-10-09T22:30:00+09:00"},
         {"episode":1,"season":0,"type":"special","date":"2024-10-02T22:30:00+09:00"}]
        """#.utf8))
        let premiere = SimklBody.locate(day: "2024-10-02", in: third, special: false)
        XCTAssertEqual(premiere?.number, 1); XCTAssertEqual(premiere?.special, false, "the episode before next week's, not the special")
        XCTAssertEqual(SimklBody.shift("2024-12-28", by: 7), "2025-01-04")
    }

    /// From Simkl's real lists (2026-11-14): several episodes on one day.
    func testEpisodesOutTheSameDay() {
        // Edgerunners: the whole season one day, each with its TVDB number.
        let season = SimklAPI.episodes(from: Data(("[" + (1...10).map {
            #"{"episode":\#($0),"type":"episode","date":"2022-09-13T16:00:00+09:00","tvdb":{"season":1,"episode":\#($0)}}"#
        }.joined(separator: ",") + "]").utf8))
        XCTAssertEqual(SimklBody.find(day: "2022-09-13", in: season, season: 1, number: 5)?.number, 5)
        XCTAssertEqual(SimklBody.find(day: "2022-09-13", in: season, season: 1, number: 10)?.number, 10)
        XCTAssertNil(SimklBody.find(day: "2022-09-13", in: season), "no number: no guess")
        XCTAssertNil(SimklBody.find(day: "2022-09-13", in: season, season: 2, number: 14), "nothing decides: no guess (TVDB's seasons place it)")

        // Without TVDB numbers: Simkl's own number decides for a regular episode.
        let premiere = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"episode","date":"2023-09-29T23:00:00+09:00"},{"episode":2,"type":"episode","date":"2023-09-29T23:00:00+09:00"},
         {"episode":3,"type":"episode","date":"2023-09-29T23:00:00+09:00"},{"episode":5,"type":"episode","date":"2023-10-06T23:00:00+09:00"}]
        """#.utf8))
        XCTAssertEqual(SimklBody.find(day: "2023-09-29", in: premiere, season: 1, number: 3)?.number, 3)
        XCTAssertEqual(SimklBody.locate(day: "2023-10-06", in: premiere, special: false, season: 1, number: 5)?.number, 5, "a weekly episode as before")

        // Demon Slayer: TMDB's specials 1–3 on one day are an OVA entry's episodes 1–3; specials
        // numbered differently: their place in the day decides, when both list as many.
        let ova = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"episode","date":"2020-08-26"},{"episode":2,"type":"episode","date":"2020-08-26"},{"episode":3,"type":"episode","date":"2020-08-26"}]
        """#.utf8))
        XCTAssertEqual(SimklBody.find(day: "2020-08-26", in: ova, special: true, season: 0, number: 2, sameDay: [1, 2, 3])?.number, 2)
        XCTAssertEqual(SimklBody.find(day: "2020-08-26", in: ova, special: true, season: 0, number: 12, sameDay: [11, 12, 13])?.number, 2)
        XCTAssertNil(SimklBody.find(day: "2020-08-26", in: ova, special: true, season: 0, number: 12, sameDay: [12, 13]), "TMDB lists fewer: no guess")
        XCTAssertNil(SimklBody.find(day: "2020-08-26", in: ova, special: true, season: 0, number: 2), "a special's number alone doesn't decide")

        // Mob Psycho: two specials a day apart: the one dated that very day.
        let specials = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"special","date":"2016-09-28"},{"episode":7,"type":"special","date":"2016-09-27"}]
        """#.utf8))
        XCTAssertEqual(SimklBody.find(day: "2016-09-27", in: specials, special: true, season: 0, number: 1, sameDay: [1])?.number, 7)
    }

    /// From Simkl's real replies (2026-11-14): Re:Zero's later cours are their own entries sharing
    /// TMDB's id; Bubble is an ONA Simkl files as anime with no TMDB id.
    func testCoursFilmsAndEntries() throws {
        let related = SimklAPI.related(from: Data(#"""
        {"title":"Re:Zero","relations":[
          {"title":"Re:Zero","year":2020,"anime_type":"tv","relation_type":"sequel","ids":{"simkl":1063491,"tmdb":"65942"}},
          {"title":"Re:Zero Memory Snow","year":2018,"anime_type":"movie","relation_type":"side story","ids":{"simkl":717117,"tmdb":"532321"}},
          {"title":"Isekai Quartet","year":2019,"anime_type":"tv","relation_type":"other","ids":{"simkl":925865,"tmdb":"87478"}}]}
        """#.utf8))
        XCTAssertEqual(related.filter { $0.tmdb == "65942" }.map(\.simkl), [1063491])
        let search = Data(#"[{"title":"Bubble","year":2022,"endpoint_type":"anime","type":"ona","ids":{"simkl_id":1800894,"slug":"bubble"}},{"title":"Bubblegum Crisis","year":1987,"ids":{"simkl_id":38420}}]"#.utf8)
        XCTAssertEqual(SimklAPI.pickAnime(from: search, title: "Bubble", year: 2022), SimklAPI.Match(simkl: 1800894, kind: "anime"))
        XCTAssertNil(SimklAPI.pickAnime(from: search, title: "Bubble", year: 2005), "another year isn't the same title")
        XCTAssertNil(SimklAPI.pickAnime(from: search, title: "Bubblegum", year: nil), "the whole title must match")

        var film = SimklJob(kind: .watch, tmdb: 1, movie: true, anime: true, name: "Bubble", year: 2022, watchedAt: "2026-11-14T05:10:00Z")
        film.entry = 1800894
        let filmItem = try XCTUnwrap(((JSONSerialization.jsonObject(with: SimklBody.body([film], simkl: nil)) as? [String: Any])?["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual(filmItem["ids"] as? [String: Int], ["simkl": 1800894], "by its Simkl entry alone")
        XCTAssertEqual(((filmItem["seasons"] as? [[String: Any]])?.first?["episodes"] as? [[String: Any]])?.first?["number"] as? Int, 1)

        var cour = watch(1); cour.entry = 1063491; cour.ownNumbering = true
        let courItem = try XCTUnwrap(((JSONSerialization.jsonObject(with: SimklBody.body([cour], simkl: nil)) as? [String: Any])?["shows"] as? [[String: Any]])?.first)
        XCTAssertEqual(courItem["ids"] as? [String: Int], ["simkl": 1063491])
        XCTAssertNil(courItem["use_tvdb_anime_seasons"])
    }

    /// Simkl's `/redirect`, as it answered on 2026-11-14: the entry's address, or its home page.
    func testRedirectAnswerAndKindCheck() {
        XCTAssertEqual(SimklAPI.match(location: "https://simkl.com/anime/509292/rezero-kara-hajimeru-isekai-seikatsu?client_id=x"), SimklAPI.Match(simkl: 509292, kind: "anime"))
        XCTAssertEqual(SimklAPI.match(location: "https://simkl.com/tv/11121/breaking-bad"), SimklAPI.Match(simkl: 11121, kind: "tv"))
        XCTAssertEqual(SimklAPI.match(location: "https://simkl.com/movies/145222/vagabond"), SimklAPI.Match(simkl: 145222, kind: "movie"))
        XCTAssertNil(SimklAPI.match(location: "https://simkl.com?client_id=x"), "Simkl's home page: no such title")
        XCTAssertNil(SimklAPI.match(location: "https://example.com/anime/1/x"))
        // TMDB 65942 is Re:Zero as a show and another film as a movie.
        XCTAssertFalse(SimklAPI.accepts(SimklAPI.Match(simkl: 145222, kind: "movie"), movie: false), "a show never takes a movie")
        XCTAssertFalse(SimklAPI.accepts(SimklAPI.Match(simkl: 11121, kind: "tv"), movie: true), "a movie never takes a show")
        XCTAssertTrue(SimklAPI.accepts(SimklAPI.Match(simkl: 543146, kind: "anime"), movie: true), "an anime film")
        XCTAssertTrue(SimklAPI.accepts(SimklAPI.Match(simkl: 509292, kind: "anime"), movie: false))
    }

    func testEveryKnownIdGoesWithTheWrite() throws {
        let external = SimklExternalIDs(imdb: "tt5607616", tvdb: 305089)
        let show = SimklBody.ids(watch(26, tmdb: 65942), simkl: nil, external: external)
        XCTAssertEqual(show["tmdb"] as? Int, 65942); XCTAssertEqual(show["imdb"] as? String, "tt5607616"); XCTAssertEqual(show["tvdb"] as? Int, 305089)
        let movie = SimklBody.ids(SimklJob(kind: .watch, tmdb: 372058, movie: true, anime: true, name: "Your Name."), simkl: 543146, external: SimklExternalIDs(imdb: "tt5311514", tvdb: 1))
        XCTAssertEqual(movie["simkl"] as? Int, 543146); XCTAssertEqual(movie["imdb"] as? String, "tt5311514"); XCTAssertNil(movie["tvdb"], "TVDB ids are for shows")
        var placed = watch(1, tmdb: 65942); placed.entry = 1063491; placed.entryIDs = ["mal": "39587", "anidb": "14792"]
        let entry = SimklBody.ids(placed, simkl: nil, external: external)
        XCTAssertEqual(entry["simkl"] as? Int, 1063491); XCTAssertEqual(entry["mal"] as? Int, 39587); XCTAssertEqual(entry["anidb"] as? Int, 14792)
        XCTAssertNil(entry["tmdb"], "a cour entry never goes by the show's shared ids"); XCTAssertNil(entry["imdb"]); XCTAssertNil(entry["tvdb"])
        let detail = SimklAPI.detail(from: Data(#"{"ids":{"simkl":509292,"mal":"31240","anilist":"21355","anidb":"11370","tmdb":"65942"},"relations":[{"year":2020,"anime_type":"tv","ids":{"simkl":1063491,"mal":"39587","tmdb":"65942"}}]}"#.utf8))
        XCTAssertEqual(detail.native, ["mal": "31240", "anilist": "21355", "anidb": "11370"])
        XCTAssertEqual(detail.related.first?.native, ["mal": "39587"])
    }

    func testSeveralTitlesInOneRequestAndNotFoundGoesToTheRightOne() throws {
        let movie = SimklJob(kind: .watch, tmdb: 550, movie: true, name: "Fight Club", year: 1999, watchedAt: "2026-11-14T21:00:00Z")
        let jobs = [watch(1), watch(2), movie]
        let groups = SimklBody.groups(jobs, simkl: { _ in nil }, external: { _ in nil })
        XCTAssertEqual(groups.count, 2)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: SimklBody.body(groups)) as? [String: Any])
        XCTAssertEqual((root["shows"] as? [[String: Any]])?.count, 1); XCTAssertEqual((root["movies"] as? [[String: Any]])?.count, 1)
        let reply = Data(#"{"added":{"episodes":2},"not_found":{"movies":[{"title":"Fight Club","year":1999,"ids":{"tmdb":550}}],"shows":[],"episodes":[]}}"#.utf8)
        XCTAssertEqual(SimklBody.notFound(reply, groups: groups), [movie.id], "only the movie Simkl names")
    }

    /// From Simkl's real lists (2026-11-14): titles break ties and place an episode Simkl dates
    /// differently (JoJo's Stone Ocean, dated by Netflix).
    func testEpisodeTitles() {
        XCTAssertEqual(SimklBody.titleKey("Mini 8-bit Shorts 1"), SimklBody.titleKey("Mini 8-Bit Shorts 1"))
        XCTAssertEqual(SimklBody.titleKey("PROJECT APPLE"), SimklBody.titleKey("Project Apple"))
        XCTAssertNil(SimklBody.titleKey("Episode 3")); XCTAssertNil(SimklBody.titleKey("Volume 1")); XCTAssertNil(SimklBody.titleKey("OAD"))
        XCTAssertNil(SimklBody.titleKey(nil))

        // Mob Psycho: two specials a day apart; the title decides before the nearer day.
        let specials = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"special","date":"2016-09-28","title":"Mini 8-Bit Shorts 1"},{"episode":7,"type":"special","date":"2016-09-27","title":"Ending of Episode 12"}]
        """#.utf8))
        XCTAssertEqual(SimklBody.find(day: "2016-09-27", in: specials, special: true, season: 0, number: 1, sameDay: [1], title: "Mini 8-bit Shorts 1")?.number, 1)
        XCTAssertEqual(SimklBody.find(day: "2016-09-27", in: specials, special: true, season: 0, number: 1, sameDay: [1])?.number, 7, "no title: the one that very day")

        // Stone Ocean on another day than TMDB's: its title, whatever the day; a generic one never.
        let ocean = SimklAPI.episodes(from: Data(#"""
        [{"episode":1,"type":"episode","date":"2021-12-01","title":"Stone Ocean"},{"episode":3,"type":"episode","date":"2021-12-01","title":"The Visitor (1)"},
         {"episode":4,"type":"episode","date":"2021-12-01","title":"Episode 4"}]
        """#.utf8))
        XCTAssertNil(SimklBody.find(day: "2022-01-22", in: ocean))
        XCTAssertEqual(SimklBody.titled("The Visitor (1)", in: ocean, special: false, anyKind: false).map(\.number), [3])
        XCTAssertEqual(SimklBody.titled("Episode 4", in: ocean, special: false, anyKind: false).count, 0)
        XCTAssertEqual(SimklBody.titled("Stone Ocean", in: ocean, special: true, anyKind: false).count, 0, "a special matches only a special in a show's own entry")
    }

    /// Scroblarr's way, as Simkl answered it (2026-11-14): an episode by its own TVDB id goes in
    /// `episodes`, and comes back by that id when Simkl doesn't know it.
    func testAnEpisodeByItsTvdbId() throws {
        var job = watch(13, season: 5, tmdb: 45790); job.tvdbEpisode = 9075730
        let groups = SimklBody.groups([job, watch(2)], simkl: { _ in nil }, external: { _ in nil })
        XCTAssertEqual(groups.count, 2)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: SimklBody.body(groups)) as? [String: Any])
        let episodes = try XCTUnwrap(root["episodes"] as? [[String: Any]])
        XCTAssertEqual((episodes.first?["ids"] as? [String: Any])?["tvdb"] as? Int, 9075730)
        XCTAssertEqual(episodes.first?["watched_at"] as? String, job.watchedAt)
        XCTAssertEqual((root["shows"] as? [[String: Any]])?.count, 1, "the other episode as before")
        let reply = Data(#"{"added":{"episodes":1,"statuses":[]},"not_found":{"movies":[],"shows":[],"episodes":[{"ids":{"tvdb":9075730},"watched_at":"2026-11-14T20:00:00.000Z"}]}}"#.utf8)
        XCTAssertEqual(SimklBody.notFound(reply, groups: groups), [job.id], "only the episode sent by that id")
    }

    /// Simkl's answer read back (its replies, 2026-11-14): how it filed each item, the other kind
    /// flagged, and an item it said nothing about checked on the account.
    func testTheAnswerIsReadBack() throws {
        let movie = SimklJob(kind: .watch, tmdb: 27205, movie: true, name: "Inception", year: 2010, watchedAt: "2026-11-14T07:00:00Z")
        var placed = watch(5, tmdb: 105248); placed.entry = 1377443; placed.ownNumbering = true
        let show = SimklJob(kind: .watch, tmdb: 1396, movie: false, name: "Breaking Bad", year: 2008, season: 1, number: 2, watchedAt: "2026-11-14T07:00:00Z")
        let groups = SimklBody.groups([movie, placed, show], simkl: { _ in nil }, external: { _ in nil })
        let reply = Data(#"""
        {"added":{"movies":1,"shows":0,"episodes":1,"statuses":[
          {"request":{"ids":{"tmdb":27205},"title":"Inception","type":"movie"},"response":{"status":"completed","simkl_type":"tv","anime_type":null}},
          {"request":{"ids":{"simkl":1377443},"type":"show"},"response":{"status":"watching","simkl_type":"anime","anime_type":"ona"}}]},
         "not_found":{"movies":[],"shows":[],"episodes":[]}}
        """#.utf8)
        let filed = SimklBody.filed(reply, groups: groups)
        XCTAssertEqual(filed[0], SimklBody.Filed(type: "tv", animeType: nil))
        XCTAssertEqual(SimklBody.otherKind(movie, try XCTUnwrap(filed[0])), "a TV show")
        XCTAssertNil(SimklBody.otherKind(placed, try XCTUnwrap(filed[1])))
        XCTAssertEqual(SimklBody.otherKind(show, SimklBody.Filed(type: "anime", animeType: "movie")), "an anime film")
        XCTAssertNil(SimklBody.otherKind(SimklJob(kind: .watch, tmdb: 912598, movie: true, anime: true, name: "Bubble"), SimklBody.Filed(type: "anime", animeType: "ona")), "an ONA film is a film")

        // Breaking Bad: neither taken nor not found, so it's asked about.
        let unclear = SimklBody.unclear(reply, groups: groups, missing: [])
        XCTAssertEqual(unclear, [2])
        let question = SimklBody.watchedQuestion(groups, asking: [1, 2])
        XCTAssertEqual(question.asked, [1, 2])
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: question.body) as? [[String: Any]])
        XCTAssertEqual((items[0]["ids"] as? [String: Any])?["simkl"] as? Int, 1377443)
        let answer = Data(#"""
        [{"ids":{"simkl":1377443},"result":true,"seasons":[{"number":1,"episodes":[{"number":4,"watched":true},{"number":5,"watched":false}]}]},
         {"ids":{"tmdb":1396},"result":"not_found"}]
        """#.utf8)
        XCTAssertEqual(SimklBody.confirmed(answer, groups: groups, asked: [1, 2]), [], "that very episode isn't watched, and the show isn't there")
        let watched = Data(#"[{"ids":{"simkl":1377443},"result":true,"seasons":[{"number":1,"episodes":[{"number":5,"watched":true}]}]},{"result":true}]"#.utf8)
        XCTAssertEqual(SimklBody.confirmed(watched, groups: groups, asked: [1, 2]), [placed.id, show.id])
        var byTVDB = watch(13, season: 5, tmdb: 45790); byTVDB.tvdbEpisode = 9075730
        XCTAssertEqual(SimklBody.watchedQuestion(SimklBody.groups([byTVDB], simkl: { _ in nil }, external: { _ in nil }), asking: [0]).asked, [],
                       "an episode sent by TVDB id isn't asked about: TVDB's seasons are next")
    }

    // MARK: Reading Simkl back (phase 2)

    /// A diary from JSON (the model's initialisers are the core package's own).
    private func diary(titles: [(id: String, name: String, category: String, tmdb: Int)], episodes: [(title: String, season: Int, number: Int)],
                       watched: [(title: String, episode: String?)]) throws -> Workspace {
        let object: [String: Any] = [
            "titles": titles.map { ["id": $0.id, "name": $0.name, "category": $0.category, "tmdbId": $0.tmdb, "overview": "", "genres": [String](),
                                    "status": "watching", "favorite": false, "notes": ""] as [String: Any] },
            "episodes": episodes.map { ["id": "\($0.title)-\($0.season)-\($0.number)", "titleId": $0.title, "season": $0.season, "number": $0.number,
                                        "name": "", "overview": ""] as [String: Any] },
            "events": watched.map { ["id": "w-\($0.title)-\($0.episode ?? "")", "operationId": "o", "titleId": $0.title, "episodeId": $0.episode ?? NSNull(),
                                     "watchedAt": "2026-11-14T07:00:00Z", "recordedAt": "2026-11-14T07:00:00Z", "origin": "manual", "version": 1] as [String: Any] },
            "locations": [Any]()
        ]
        return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// From the test account's real library (2026-11-14): movies and shows by TMDB id; anime through
    /// where the diary's episodes were placed (Re:Zero's second cour has no TMDB id on Simkl).
    func testSimklsLibraryReadsInTheDiarysTerms() throws {
        let workspace = try diary(titles: [("inc", "Inception", "movie", 27205), ("bb", "Breaking Bad", "show", 1396),
                                       ("rz", "Re:ZERO", "anime", 65942), ("yn", "Your Name.", "anime-movie", 372058)],
                              episodes: [("bb", 1, 2), ("rz", 1, 26), ("rz", 1, 27)],
                              watched: [("inc", nil), ("bb", "bb-1-2"), ("rz", "rz-1-26"), ("rz", "rz-1-27")])
        let placements = ["65942:1:26": SimklPlacement(entry: 1063491, season: 1, number: 1, at: .now),
                          "65942:1:27": SimklPlacement(entry: nil, season: nil, number: nil, at: .now)]
        let mapping = SimklLibrary.mapping(placements: placements, diary: workspace)
        var library = TraktLibrary()
        SimklLibrary.apply("movies", Data(#"{"movies":[{"last_watched_at":"2026-11-14T07:00:00Z","user_rated_at":"2026-11-14T07:37:48Z","user_rating":8,"status":"completed","movie":{"title":"Inception","year":2010,"ids":{"simkl":472214,"imdb":"tt1375666","tmdb":"27205"}}}]}"#.utf8), mapping: mapping, into: &library)
        SimklLibrary.apply("shows", Data(#"{"shows":[{"status":"watching","show":{"title":"Breaking Bad","ids":{"simkl":11121,"tmdb":"1396"}},"seasons":[{"number":1,"episodes":[{"number":2,"watched_at":"2026-11-14T07:00:00Z"}]}]},{"status":"dropped","added_to_watchlist_at":"2026-11-14T07:37:50Z","show":{"title":"Severance","ids":{"simkl":1203662,"tmdb":"95396"}}}]}"#.utf8), mapping: mapping, into: &library)
        SimklLibrary.apply("anime", Data(#"""
        {"anime":[{"status":"plantowatch","added_to_watchlist_at":"2026-11-14T07:37:50Z","anime_type":"movie","show":{"title":"Kimi no Na wa.","ids":{"simkl":543146,"tmdb":"372058"}}},
          {"status":"watching","anime_type":"tv","show":{"title":"Re:Zero kara Hajimeru Isekai Seikatsu","ids":{"simkl":1063491,"mal":"39587"}},"seasons":[{"number":1,"episodes":[{"number":1,"watched_at":"2026-11-14T07:00:00Z"},{"number":2,"watched_at":"2026-11-14T07:00:00Z"}]}]},
          {"status":"watching","anime_type":"ova","show":{"title":"Kimetsu Gakuen","ids":{"simkl":2853600,"tmdb":"312924"}},"seasons":[{"number":1,"episodes":[{"number":2,"watched_at":"2026-11-14T07:00:00Z"}]}]}]}
        """#.utf8), mapping: mapping, into: &library)
        XCTAssertTrue(library.plays.contains { $0.title.tmdbId == 27205 && $0.title.kind == .movie })
        XCTAssertTrue(library.plays.contains { $0.title.tmdbId == 1396 && $0.season == 1 && $0.episode == 2 })
        XCTAssertTrue(library.plays.contains { $0.title.tmdbId == 65942 && $0.season == 1 && $0.episode == 26 }, "the cour's episode 1 is the diary's S1 E26")
        XCTAssertEqual(library.plays.filter { $0.title.tmdbId == 65942 }.count, 1)
        XCTAssertEqual(library.ratings.first?.rating, 8)
        XCTAssertEqual(library.watchlist.map(\.title.tmdbId), [372058], "an anime film by its TMDB id")
        XCTAssertEqual(library.dropped.map(\.title.tmdbId), [95396])
        XCTAssertEqual(library.skipped, 3, "the cour's episode 2 (no diary episode there) and the OVA (a TMDB id the diary doesn't have) are counted, not guessed")

        // The diary as compared: Re:Zero S1 E27, which Simkl lists nowhere, is left out; so is what Simkl didn't keep.
        let compared = SimklLibrary.comparable(workspace, placements: placements, notKept: ["show:1396:1:2"])
        XCTAssertEqual(Set(compared.events.map(\.id)), ["w-inc-", "w-rz-rz-1-26"])
    }

    /// Simkl dates Date A Live a week early (its episode 1 on 31 March 2013; the show began on
    /// 6 April), so by date each diary episode landed one along (test account 2026-11-15). The
    /// episode titled as TMDB titles it comes first; without a title, the date still decides.
    func testTheSameTitleWinsOverASimklDateAWeekOff() {
        let titles = ["April 1x", "Another Close Encounter", "For the Sky and the Sword", "Sullen Rain", "Frozen Ground", "Romantic Hot Springs",
                      "Visitors", "Triple Capriccio", "Frenzied Nightmare", "Flame Spirit (Ifrit)", "Countdown", "That Which Cannot Be Forgiven"]
        let simkl = titles.enumerated().map { index, title in
            SimklAPI.Episode(number: index + 1, day: SimklBody.shift("2013-03-31", by: 7 * index), special: false, tvdbSeason: nil, tvdbEpisode: nil, title: title)
        }
        XCTAssertEqual(SimklBody.locate(day: "2013-06-15", in: simkl, special: false, anyKind: false, title: "Countdown")?.number, 11, "not 12, dated 16 June")
        XCTAssertEqual(SimklBody.locate(day: "2013-04-06", in: simkl, special: false, anyKind: false, title: "April 1x")?.number, 1)
        XCTAssertEqual(SimklBody.locate(day: "2013-06-15", in: simkl, special: false, anyKind: false)?.number, 12, "no title: the date, as before")
        XCTAssertEqual(SimklBody.locate(day: "2014-06-15", in: simkl, special: false, anyKind: false, title: "Countdown")?.number, nil,
                       "a title a year away is another episode")
    }

    /// I'm Standing on a Million Lives: TMDB dates E4 with E5 (30 October) and spells it "Kahvel";
    /// Simkl dates it a week earlier as "Kavhel" (new account, 2026-11-15). The same TVDB number,
    /// within two weeks, places it on Simkl's E4, not E5.
    func testTheSameNumberWinsWhenTMDBDatesTwoEpisodesOneDay() {
        let simkl = [(1, "2020-10-02", "Unqualified Heroes"), (2, "2020-10-09", "This City I Hate So Much"), (3, "2020-10-16", "Help Me"),
                     (4, "2020-10-23", "Kavhel of Cortonel"), (5, "2020-10-30", "What a Life Is Worth"), (6, "2020-11-06", "The Ancient Ruins")]
            .map { SimklAPI.Episode(number: $0.0, day: $0.1, special: false, tvdbSeason: 1, tvdbEpisode: $0.0, title: $0.2) }
        XCTAssertEqual(SimklBody.locate(day: "2020-10-30", in: simkl, special: false, anyKind: false, season: 1, number: 4, sameDay: [4, 5], title: "Kahvel of Cortonel")?.number, 4)
        XCTAssertEqual(SimklBody.locate(day: "2020-10-30", in: simkl, special: false, anyKind: false, season: 1, number: 5, sameDay: [4, 5], title: "What a Life Is Worth")?.number, 5)
        XCTAssertNil(SimklBody.locate(day: "2021-10-30", in: simkl, special: false, anyKind: false, season: 2, number: 4), "a later season's E4 isn't this one")
    }

    /// A change Simkl refused is one Not kept row, however often it's refused, and says what it was.
    @MainActor func testARefusedChangeIsKnownByItsDiaryPlace() {
        var placed = watch(11, tmdb: 46004); placed.diarySeason = 1; placed.diaryNumber = 11; placed.season = 1; placed.number = 12; placed.entry = 37935
        XCTAssertEqual(SimklMirror.changeKey(placed), SimklMirror.changeKey(watch(11, tmdb: 46004)), "the same diary episode, wherever it was placed")
        let rating = SimklJob(kind: .rate, tmdb: 760161, movie: true, name: "Date A Bullet: Nightmare or Queen", rating: 8)
        XCTAssertNotEqual(SimklMirror.changeKey(rating), SimklMirror.changeKey(SimklJob(kind: .watch, tmdb: 760161, movie: true, name: "Date A Bullet: Nightmare or Queen")))
        XCTAssertEqual(SimklMirror.notKeptLabel(rating), "Date A Bullet: Nightmare or Queen · Rating")
        XCTAssertFalse(SimklPlacement(entry: 37935, season: 1, number: 12, at: .now).isCurrent(for: "1:1:12"), "placed before titles counted: placed again")
        XCTAssertTrue(SimklPlacement(entry: 37935, season: 1, number: 11, at: .now, rule: SimklPlacement.currentRule).isCurrent(for: "1:1:11"))
    }

    /// Simkl files some films as an OVA or ONA with no TMDB id (Voices of a Distant Star as the OVA
    /// "Hoshi no Koe", test account 2026-11-15): the entry the diary's film was placed in is read as
    /// that film, its watch and rating included.
    func testAFilmSimklFilesAsAnOVAIsReadAsTheFilm() throws {
        let workspace = try diary(titles: [("vd", "Voices of a Distant Star", "anime-movie", 37228)], episodes: [], watched: [("vd", nil)])
        let mapping = SimklLibrary.mapping(placements: ["movie:37228": SimklPlacement(entry: 37116, season: nil, number: nil, at: .now)], diary: workspace)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", Data(#"{"anime":[{"status":"completed","last_watched_at":"2021-04-06T18:30:00Z","user_rating":7,"user_rated_at":"2026-11-15T05:24:57Z","anime_type":"ova","watched_episodes_count":1,"show":{"title":"Hoshi no Koe","ids":{"simkl":37116,"mal":"256","anidb":"104"}},"seasons":[{"number":1,"episodes":[{"number":1,"watched_at":"2021-04-06T18:30:00Z"}]}]}]}"#.utf8), mapping: mapping, into: &library)
        XCTAssertEqual(library.plays.map(\.title.diaryKey), ["movie:37228"])
        XCTAssertEqual(library.ratings.map(\.rating), [7])
        XCTAssertEqual(library.skipped, 0, "no longer an unreadable show")
    }

    /// A missing diary watch says where it was placed on Simkl, so a mismatch shows whether it's
    /// the placing or the reading (Immortal King's first episodes, new account 2026-11-15).
    func testAMissingWatchSaysWhereItWasPlaced() {
        let missing = TraktComparison.Difference(title: "The Daily Life of the Immortal King S1E1", detail: "1 in the diary, 0 on Simkl", key: "tv:98123|s1e1")
        let placed = ["98123:1:1": SimklPlacement(entry: 1258030, season: 1, number: 4, at: .now),
                      "723343": SimklPlacement(entry: nil, season: nil, number: nil, at: .now),
                      "movie:723343": SimklPlacement(entry: 1168961, season: 1, number: 2, at: .now)]
        XCTAssertEqual(SimklMirror.placementNote(missing, placements: placed).detail, "1 in the diary, 0 on Simkl · on Simkl: entry 1258030, episode 4")
        XCTAssertEqual(SimklMirror.placementNote(missing, placements: ["98123:1:1": SimklPlacement(entry: nil, season: nil, number: nil, at: .now)]).detail,
                       "1 in the diary, 0 on Simkl · not placed on Simkl")
        XCTAssertEqual(SimklMirror.placementNote(missing, placements: [:]), missing, "never placed: as it was")
        let film = TraktComparison.Difference(title: "Date A Bullet: Nightmare or Queen", detail: "1 in the diary, 0 on Simkl", key: "movie:723343")
        XCTAssertEqual(SimklMirror.placementNote(film, placements: placed).detail, "1 in the diary, 0 on Simkl · on Simkl: entry 1168961, part 2")
    }

    /// A film placed in a series entry (Simkl's search answered with Immortal King's 15-episode
    /// ONA) doesn't make the series a film: its episodes are still read (test account 2026-11-15).
    func testASeriesEntryAFilmLandedInIsStillTheSeries() throws {
        let workspace = try diary(titles: [("ik", "The Daily Life of the Immortal King", "anime", 98123), ("fm", "A Film", "anime-movie", 555)],
                                  episodes: [("ik", 1, 1), ("ik", 1, 2)], watched: [("ik", "ik-1-1"), ("ik", "ik-1-2"), ("fm", nil)])
        let placements = ["98123:1:1": SimklPlacement(entry: 1258030, season: 1, number: 1, at: .now),
                          "98123:1:2": SimklPlacement(entry: 1258030, season: 1, number: 2, at: .now),
                          "movie:555": SimklPlacement(entry: 1258030, season: nil, number: nil, at: .now)]
        let mapping = SimklLibrary.mapping(placements: placements, diary: workspace)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", Data(#"{"anime":[{"status":"watching","last_watched_at":"2021-04-06T18:30:00Z","anime_type":"ona","watched_episodes_count":2,"total_episodes_count":15,"show":{"title":"Xian Wang De Richang Shenghuo","ids":{"simkl":1258030,"tmdb":"98123"}},"seasons":[{"number":1,"episodes":[{"number":1,"watched_at":"2021-04-06T18:30:00Z"},{"number":2,"watched_at":"2021-04-06T18:30:00Z"}]}]}]}"#.utf8), mapping: mapping, into: &library)
        XCTAssertEqual(library.plays.map { "\($0.title.diaryKey ?? "")|\($0.season ?? 0)|\($0.episode ?? 0)" }.sorted(), ["tv:98123|1|1", "tv:98123|1|2"])
    }

    /// Immortal King is Chinese, so the diary has it as a show, sent by TMDB id and never placed;
    /// Simkl files it as an anime ONA numbered as the show (new account, 2026-11-15). Read in that
    /// numbering, not skipped as unplaced anime.
    func testAShowSimklFilesAsAnimeIsReadAsTheShow() throws {
        let workspace = try diary(titles: [("ik", "The Daily Life of the Immortal King", "show", 98123)],
                                  episodes: [("ik", 1, 1), ("ik", 1, 2)], watched: [("ik", "ik-1-1"), ("ik", "ik-1-2")])
        let mapping = SimklLibrary.mapping(placements: [:], diary: workspace)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", Data(#"{"anime":[{"status":"watching","anime_type":"ona","watched_episodes_count":2,"total_episodes_count":15,"show":{"title":"Xian Wang De Richang Shenghuo","ids":{"simkl":1258030,"tmdb":"98123"}},"seasons":[{"number":1,"episodes":[{"number":1,"watched_at":"2021-04-06T18:30:00Z"},{"number":2,"watched_at":"2021-04-06T18:30:00Z"}]}]}]}"#.utf8), mapping: mapping, into: &library)
        XCTAssertEqual(library.plays.map { "\($0.title.diaryKey ?? "")|\($0.season ?? 0)|\($0.episode ?? 0)" }.sorted(), ["tv:98123|1|1", "tv:98123|1|2"])
        XCTAssertEqual(library.skipped, 0)
    }

    /// Simkl keeps Date a Bullet as one film entry in two parts (Dead or Bullet, Nightmare or Queen;
    /// test account 2026-11-15). Each diary film is placed on its part by title, read back from it,
    /// and both share the entry's one rating.
    @MainActor func testAFilmEntryInPartsIsReadAsEachPartsFilm() throws {
        let parts = [SimklAPI.Episode(number: 1, day: "2020-08-14", special: false, tvdbSeason: nil, tvdbEpisode: nil, title: "Dead or Bullet"),
                     SimklAPI.Episode(number: 2, day: "2020-11-13", special: false, tvdbSeason: nil, tvdbEpisode: nil, title: "Nightmare or Queen")]
        XCTAssertEqual(SimklBody.filmPart("Date A Bullet: Nightmare or Queen", in: parts), 2)
        XCTAssertEqual(SimklBody.filmPart("Date A Bullet: Dead or Bullet", in: parts), 1)
        XCTAssertNil(SimklBody.filmPart("Date A Bullet", in: parts), "no part's title in the name: not placed")
        XCTAssertEqual(SimklBody.seriesName("Date A Bullet: Nightmare or Queen"), "Date A Bullet", "Simkl's search finds the entry only by this")
        XCTAssertNil(SimklBody.seriesName("A Whisker Away"))

        let workspace = try diary(titles: [("db", "Date A Bullet: Dead or Bullet", "anime-movie", 685099), ("nq", "Date A Bullet: Nightmare or Queen", "anime-movie", 760161)],
                                  episodes: [], watched: [("db", nil), ("nq", nil)])
        let mapping = SimklLibrary.mapping(placements: ["movie:760161": SimklPlacement(entry: 1168961, season: 1, number: 2, at: .now)], diary: workspace)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", Data(#"{"anime":[{"status":"completed","last_watched_at":"2021-04-06T18:30:00Z","user_rating":8,"user_rated_at":"2026-11-15T05:24:57Z","anime_type":"movie","watched_episodes_count":2,"total_episodes_count":2,"show":{"title":"Date a Bullet","ids":{"simkl":1168961,"tmdb":"685099"}},"seasons":[{"number":1,"episodes":[{"number":1,"watched_at":"2021-04-05T18:30:00Z"},{"number":2,"watched_at":"2021-04-06T18:30:00Z"}]}]}]}"#.utf8), mapping: mapping, into: &library)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: library.plays.compactMap { play in play.title.diaryKey.map { ($0, play.watchedAt ?? "") } }),
                       ["movie:685099": "2021-04-05T18:30:00Z", "movie:760161": "2021-04-06T18:30:00Z"])
        XCTAssertEqual(library.ratings.map(\.rating), [8, 8], "one rating for both parts")
        XCTAssertEqual(library.skipped, 0)

        // Sent, and taken off, as that part alone; known as the film wherever it was placed.
        var watch = SimklJob(kind: .watch, tmdb: 760161, movie: true, anime: true, name: "Date A Bullet: Nightmare or Queen", watchedAt: "2021-04-06T18:30:00Z")
        let unplacedKey = SimklMirror.changeKey(watch)
        watch.entry = 1168961; watch.season = 1; watch.number = 2; watch.ownNumbering = true
        XCTAssertEqual(SimklMirror.changeKey(watch), unplacedKey)
        var off = watch; off.kind = .unwatch; off.watchedAt = nil
        for job in [watch, off] {
            let body = SimklBody.body(SimklBody.groups([job], simkl: { _ in nil }, external: { _ in nil }))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let episode = try XCTUnwrap(((((root["shows"] as? [[String: Any]])?.first?["seasons"] as? [[String: Any]])?.first)?["episodes"] as? [[String: Any]])?.first)
            XCTAssertEqual(episode["number"] as? Int, 2, "\(job.kind): part 2 alone")
            XCTAssertEqual(episode["watched_at"] != nil, job.kind == .watch)
        }
    }

    /// Simkl answered for TONIKAWA (the show was on the list from its rating) but kept no episode
    /// (test account 2026-11-15): an anime episode counts as sent only when that episode is watched
    /// there; a TV episode sent by its ids still counts once Simkl has the title.
    func testAnAnimeEpisodeCountsAsSentOnlyWhenSimklHasThatEpisode() throws {
        let toni = SimklJob(kind: .watch, tmdb: 100049, movie: false, anime: true, name: "TONIKAWA", year: 2020, season: 1, number: 1, airedOn: nil, watchedAt: "2021-04-07T12:04:00Z")
        let drama = SimklJob(kind: .watch, tmdb: 1396, movie: false, name: "Breaking Bad", season: 1, number: 3, watchedAt: "2020-03-03T20:00:00Z")
        let groups = SimklBody.groups([toni, drama], simkl: { _ in nil }, external: { _ in nil })
        let reply = Data(#"{"added":{"episodes":0,"statuses":[{"request":{"ids":{"tmdb":100049},"type":"show"},"response":{"status":"watching","simkl_type":"anime","anime_type":"tv"}},{"request":{"ids":{"tmdb":1396},"type":"show"},"response":{"status":"watching","simkl_type":"tv"}}]},"not_found":{"movies":[],"shows":[],"episodes":[]}}"#.utf8)
        XCTAssertEqual(SimklBody.toCheck(reply, groups: groups, missing: []), [0], "the anime is checked although Simkl answered for it")

        let question = SimklBody.watchedQuestion(groups, asking: [0, 1])
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: question.body) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["type"] as? String }, ["show", "show"], "a TMDB id alone can name a movie")

        let dropped = Data(#"[{"result":true,"list":"watching","seasons":[{"number":1,"episodes":[{"number":1,"watched":false},{"number":2,"watched":false}]}]},{"result":true,"list":"watching"}]"#.utf8)
        XCTAssertEqual(SimklBody.confirmed(dropped, groups: groups, asked: [0, 1]), [drama.id], "the show listed with nothing watched isn't the episode")
        let kept = Data(#"[{"result":true,"list":"watching","seasons":[{"number":1,"episodes":[{"number":1,"watched":true}]}]}]"#.utf8)
        XCTAssertEqual(SimklBody.confirmed(kept, groups: groups, asked: [0]), [toni.id])
    }

    /// Force Match takes a whole title off Simkl with no seasons (all of it), apart from episodes.
    func testAWholeTitleComesOffWithoutSeasons() throws {
        var whole = SimklJob(kind: .unwatch, tmdb: 95396, movie: false, name: "Severance"); whole.wholeTitle = true
        var episode = SimklJob(kind: .unwatch, tmdb: 95396, movie: false, name: "Severance", season: 1, number: 2)
        episode.watchedAt = nil
        let groups = SimklBody.groups([whole, episode], simkl: { _ in nil }, external: { _ in nil })
        XCTAssertEqual(groups.count, 2, "the whole title and the episode go as separate items")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: SimklBody.body(groups)) as? [String: Any])
        let shows = try XCTUnwrap(root["shows"] as? [[String: Any]])
        XCTAssertEqual(shows.filter { $0["seasons"] == nil }.count, 1)
        XCTAssertEqual(shows.filter { $0["seasons"] != nil }.count, 1)
    }

    func testSearchAnswer() {
        XCTAssertEqual(SimklAPI.match(from: Data(#"[{"type":"anime","title":"Attack on Titan","ids":{"simkl":39687,"slug":"attack-on-titan"}}]"#.utf8)),
                       SimklAPI.Match(simkl: 39687, kind: "anime"))
        XCTAssertNil(SimklAPI.match(from: Data("[]".utf8)))
    }

    func testAnimeEpisodesGoByTmdbSoSimklPicksTheCour() {
        let match = SimklAPI.Match(simkl: 39687, kind: "anime")
        XCTAssertNil(SimklBody.pin(watch(1), match), "anime episodes: TMDB id and TVDB seasons, no pinned cour")
        XCTAssertEqual(SimklBody.pin(SimklJob(kind: .watch, tmdb: 1, movie: true, anime: true, name: "Bubble"), match), 39687)
        XCTAssertEqual(SimklBody.pin(SimklJob(kind: .watch, tmdb: 1399, movie: false, name: "Game of Thrones", season: 1, number: 1), match), 39687)
        XCTAssertNil(SimklBody.pin(SimklJob(kind: .watch, tmdb: 1, movie: true, name: "Bubble"), nil), "nothing found: TMDB id, title and year alone")
        XCTAssertEqual(SimklBody.missingPart(Data(#"{"added":{"episodes":0},"not_found":{"shows":[{"ids":{"tmdb":65942}}]}}"#.utf8)), #"{"shows":[{"ids":{"tmdb":65942}}]}"#)
    }

    @MainActor func testStatusesMapToSimklLists() {
        XCTAssertEqual(SimklMirror.list(for: "planned", movie: true), "plantowatch")
        XCTAssertEqual(SimklMirror.list(for: "paused", movie: false), "hold")
        XCTAssertNil(SimklMirror.list(for: "watching", movie: true), "Simkl has no Watching for movies")
        XCTAssertNil(SimklMirror.list(for: "queue", movie: false))
    }

    // MARK: Sign-in

    /// Simkl signs in through the shared web sign-in: its page, PKCE, back to twildiary://auth/simkl.
    func testSignInPageAndReply() throws {
        let request = try XCTUnwrap(ProviderWebSignIn.start(provider: .simkl, clientId: SimklAccount.clientId) { Array(repeating: 7, count: $0) })
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(request.url.host, "simkl.com"); XCTAssertEqual(request.url.path, "/oauth2/authorize")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "twildiary://auth/simkl")
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "media:read media:write")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        let back = try XCTUnwrap(URL(string: "twildiary://auth/simkl?code=abc&state=\(request.state)"))
        XCTAssertEqual(try ProviderWebSignIn.code(from: back, for: request), "abc")
        XCTAssertThrowsError(try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?code=abc&state=other")!, for: request))
        XCTAssertThrowsError(try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?error=access_denied&state=\(request.state)")!, for: request))
        let body = String(decoding: ProviderWebSignIn.tokenBody(code: "abc", for: request), as: UTF8.self)
        XCTAssertTrue(body.contains("redirect_uri=twildiary%3A%2F%2Fauth%2Fsimkl")); XCTAssertTrue(body.contains("code_verifier="))
    }

    /// Simkl is a service of its own, never the main tracker; a saved "simkl" never becomes main.
    func testSimklIsKeptInSyncButNeverMain() throws {
        XCTAssertFalse(MainTracker.offered.contains(.simkl)); XCTAssertEqual(MainTracker.alsoSynced, [.simkl])
        XCTAssertNil(MainTracker(main: "simkl")); XCTAssertEqual(MainTracker(main: "wetrakr"), .wetrakr)
        var settings = ProviderConnectionSettings()
        var simkl = settings.simkl
        simkl.clientId = SimklAccount.clientId; simkl.accessToken = "token"; simkl.enabled = true
        settings.setConfig(simkl)
        XCTAssertTrue(settings.config(for: .simkl).isAuthenticated)
        XCTAssertFalse(settings.activeDirectLoggingProviders.contains(.simkl), "Simkl's edits go through its own sync")
        let saved = try JSONDecoder().decode(ProviderConnectionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.simkl.accessToken, "token")
        let old = Data(#"{"trakt":{"provider":"trakt","enabled":false,"loggingMethod":"server_and_direct"},"mdblist":{"provider":"mdblist","enabled":false,"loggingMethod":"server_and_direct"},"simkl":{"provider":"simkl","enabled":true,"loggingMethod":"server_and_direct","accessToken":"old"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ProviderConnectionSettings.self, from: old).simkl.accessToken, "the first integration's entry isn't read")
    }

    func testTokensNeedWriteAccess() throws {
        let tokens = try SimklAccount.tokens(from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":604800,"scope":"media:read media:write"}"#.utf8), status: 200, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(tokens.expires, Date(timeIntervalSince1970: 604_800))
        XCTAssertThrowsError(try SimklAccount.tokens(from: Data(#"{"access_token":"a","scope":"media:read"}"#.utf8), status: 200), "read-only is refused")
        XCTAssertThrowsError(try SimklAccount.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400))
    }


    func testTodaysRequestsAreCountedOnSimklsUtcDay() {
        let noon = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SimklUsage.dayKey(noon), "2027-01-15")
        UserDefaults.standard.removeObject(forKey: "simkl.addon.usage")
        SimklUsage.counted(now: noon); SimklUsage.counted(now: noon)
        XCTAssertEqual(SimklUsage.today(now: noon).count, 2)
        XCTAssertNil(SimklUsage.today(now: noon).limitReachedAt)
        SimklUsage.limitReached(now: noon)
        XCTAssertEqual(SimklUsage.today(now: noon).limitReachedAt, noon)
        // The next UTC day starts from nothing.
        XCTAssertEqual(SimklUsage.today(now: noon.addingTimeInterval(86_400)).count, 0)
        UserDefaults.standard.removeObject(forKey: "simkl.addon.usage")
    }

    func testSimklsOwnDailyCountIsRead() throws {
        let key = "providerQuota." + SimklAPI.quotaHost
        UserDefaults.standard.removeObject(forKey: key)
        let url = try XCTUnwrap(URL(string: "https://api.simkl.com/sync/history"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        SimklAPI.recordQuota(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-RateLimit-Limit": "500", "X-RateLimit-Remaining": "278"]), now: now)
        let daily = try XCTUnwrap(ProviderQuota.daily(host: SimklAPI.quotaHost, now: now))
        XCTAssertEqual(daily.used, 222); XCTAssertEqual(daily.limit, 500)
        XCTAssertGreaterThan(try XCTUnwrap(daily.resetsAt), now)
        // A new sign-in's first answer has no count: nothing changes.
        SimklAPI.recordQuota(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]), now: now)
        XCTAssertEqual(ProviderQuota.daily(host: SimklAPI.quotaHost, now: now)?.used, 222)
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testSendProgressIsReadFromTheProgressLine() {
        XCTAssertEqual(SendProgress.fraction("Sending 3 of 10: 100 watches…") ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(SendProgress.fraction("Changing 1,200 of 1,828: 50 ratings…") ?? -1, 1199.5 / 1828, accuracy: 0.001)
        XCTAssertNil(SendProgress.fraction("Reading both sides…"))
        XCTAssertNil(SendProgress.fraction(nil))
    }

    /// Angel Beats! (owner's account, 2026-11-15): TMDB dates Stairway to Heaven (S0 E2) and Another
    /// Epilogue (S0 E3) both 22 December 2010; Simkl numbers them specials 2 and 1, dated the 4th and
    /// the 22nd. By date both landed on special 1, and special 2 was never marked.
    func testASpecialTitledTheSameComesBeforeTheDate() {
        let simkl = [SimklAPI.Episode(number: 1, day: "2010-12-22", special: true, tvdbSeason: nil, tvdbEpisode: nil, title: "Another Epilogue"),
                     SimklAPI.Episode(number: 2, day: "2010-12-04", special: true, tvdbSeason: nil, tvdbEpisode: nil, title: "Stairway to Heaven"),
                     SimklAPI.Episode(number: 3, day: "2015-06-24", special: true, tvdbSeason: nil, tvdbEpisode: nil, title: "Hell's Kitchen"),
                     SimklAPI.Episode(number: 1, day: "2010-04-03", special: false, tvdbSeason: 1, tvdbEpisode: 1, title: "Departure")]
        XCTAssertEqual(SimklBody.locate(day: "2010-12-22", in: simkl, special: true, anyKind: false, season: 0, number: 2, title: "Stairway to Heaven")?.number, 2)
        XCTAssertEqual(SimklBody.locate(day: "2010-12-22", in: simkl, special: true, anyKind: false, season: 0, number: 3, title: "Another Epilogue")?.number, 1)
        XCTAssertEqual(SimklBody.locate(day: "2015-06-24", in: simkl, special: true, anyKind: false, season: 0, number: 5)?.number, 3, "no title: the date, as before")
        XCTAssertNil(SimklBody.locate(day: "2010-04-03", in: simkl, special: true, anyKind: false, season: 0, number: 9, title: "Departure"), "a special matches only a special")
    }
    /// Rule 5 changed only specials: other places made with rule 4 aren't made again.
    func testOnlySpecialsArePlacedAgainForRuleFive() {
        let four = SimklPlacement(entry: 38481, season: 0, number: 1, at: .now, rule: 4)
        XCTAssertFalse(four.isCurrent(for: "42942:0:2"))
        XCTAssertTrue(four.isCurrent(for: "42942:1:2"))
        XCTAssertTrue(four.isCurrent(for: "movie:372058"))
        XCTAssertTrue(four.isCurrent(for: "show:68096"))
        XCTAssertFalse(SimklPlacement(entry: 1, season: 1, number: 1, at: .now, rule: 3).isCurrent(for: "42942:1:2"))
        XCTAssertTrue(SimklPlacement(entry: 38481, season: 0, number: 2, at: .now, rule: 5).isCurrent(for: "42942:0:2"))
        XCTAssertTrue(SimklPlacement(entry: 38481, season: 0, number: 2, at: .now, rule: 6).isCurrent(for: "42942:0:2"), "6: the anime map asked first")
    }
    /// ViVid Strike! on Plan to watch (test account, 2026-11-15): Simkl lists it as anime with no
    /// TMDB id; its entry, found once, links it back to the diary's planned series.
    func testAPlannedAnimeSeriesIsReadThroughItsEntry() throws {
        let workspace = try diary(titles: [("vs", "ViVid Strike!", "anime", 68096)], episodes: [], watched: [])
        let row = Data(#"{"anime":[{"status":"plantowatch","added_to_watchlist_at":"2026-11-15T14:00:00Z","anime_type":"tv","total_episodes_count":12,"show":{"title":"ViVid Strike!","year":2016,"ids":{"simkl":612999,"mal":"33589","anilist":"21871"}}}]}"#.utf8)
        var before = TraktLibrary()
        SimklLibrary.apply("anime", row, mapping: SimklLibrary.mapping(placements: [:], diary: workspace), into: &before)
        XCTAssertTrue(before.watchlist.isEmpty, "without its entry it can't be read")
        var after = TraktLibrary()
        let placements = ["show:68096": SimklPlacement(entry: 612999, season: nil, number: nil, at: .now, rule: SimklPlacement.currentRule)]
        SimklLibrary.apply("anime", row, mapping: SimklLibrary.mapping(placements: placements, diary: workspace), into: &after)
        XCTAssertEqual(after.watchlist.map(\.title.tmdbId), [68096])
        XCTAssertEqual(after.watchlist.first?.title.name, "ViVid Strike!")
    }

    /// ViVid Strike! (owner's account, 2026-11-15): Planned, on Simkl's Plan to watch with no TMDB
    /// id, and not placed yet. The anime map links it at read time.
    func testTheAnimeMapLinksAPlannedTitleBeforeItsPlaced() throws {
        let workspace = try diary(titles: [("vs", "ViVid Strike!", "anime", 68096)], episodes: [], watched: [])
        var map = AnimeMap(); map.simklShows["68096"] = 612999
        let row = Data(#"{"anime":[{"status":"plantowatch","anime_type":"tv","total_episodes_count":12,"show":{"title":"ViVid Strike!","year":2016,"ids":{"simkl":612999,"anilist":"21871"}}}]}"#.utf8)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", row, mapping: SimklLibrary.mapping(placements: [:], diary: workspace, map: map), into: &library)
        XCTAssertEqual(library.watchlist.map(\.title.tmdbId), [68096])
    }
    /// A plain show Simkl files as anime (Immortal King) still reads in the show's own numbering
    /// when the map links its entry.
    func testAPlainShowLinkedByTheMapReadsAsAShow() throws {
        let workspace = try diary(titles: [("ik", "The Daily Life of the Immortal King", "show", 98123)], episodes: [("ik", 1, 2)], watched: [("ik", "ik-1-2")])
        var map = AnimeMap(); map.simklShows["98123"] = 1250000
        let row = Data(#"{"anime":[{"status":"watching","anime_type":"ona","total_episodes_count":15,"show":{"title":"Xian Wang de Richang Shenghuo","ids":{"simkl":1250000}},"seasons":[{"number":1,"episodes":[{"number":2,"watched_at":"2026-11-14T07:00:00Z"}]}]}]}"#.utf8)
        var library = TraktLibrary()
        SimklLibrary.apply("anime", row, mapping: SimklLibrary.mapping(placements: [:], diary: workspace, map: map), into: &library)
        XCTAssertEqual(library.plays.map { "\($0.title.tmdbId ?? 0)|s\($0.season ?? -1)e\($0.episode ?? -1)" }, ["98123|s1e2"])
        XCTAssertEqual(library.skipped, 0)
    }

    // MARK: Trash

    /// A trashed title Simkl still lists, in any way, goes off Simkl again on the next check
    /// (Akame ga Kill! stayed on Plan to watch until Force Match, 2026-11-19); one it doesn't list,
    /// or lists as the other kind, is left alone.
    func testTheCheckFindsTrashedTitlesSimklStillLists() throws {
        func title(_ id: String, _ category: String, tmdb: Int) throws -> MediaTitle {
            try JSONDecoder().decode(MediaTitle.self, from: Data(#"{"id":"\#(id)","name":"\#(id)","category":"\#(category)","year":2014,"tmdbId":\#(tmdb),"overview":"","genres":[],"status":"planned","favorite":false,"notes":""}"#.utf8))
        }
        let planned = try title("akame", "anime", tmdb: 61223)
        let rated = try title("rated-film", "movie", tmdb: 500)
        let watched = try title("watched-show", "show", tmdb: 600)
        let dropped = try title("dropped-show", "show", tmdb: 700)
        let otherKind = try title("film-700", "movie", tmdb: 700)
        func ref(_ kind: TraktTitleRef.Kind, _ tmdb: Int) -> TraktTitleRef { TraktTitleRef(kind: kind, traktId: nil, tmdbId: tmdb, name: "x") }
        let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref(.show, 600), season: 1, episode: 1, watchedAt: nil)],
                                   ratings: [TraktRating(title: ref(.movie, 500), rating: 7, ratedAt: nil)],
                                   watchlist: [TraktListed(title: ref(.show, 61223), listedAt: nil)],
                                   dropped: [TraktListed(title: ref(.show, 700), listedAt: nil)])
        let found = SimklMirror.trashedOnSimkl(library, trashed: [planned, rated, watched, otherKind])
        XCTAssertEqual(found.map(\.id), ["akame", "rated-film", "watched-show"])
        XCTAssertEqual(SimklMirror.trashedOnSimkl(library, trashed: [dropped]).map(\.id), ["dropped-show"], "listed as Dropped")
        XCTAssertTrue(SimklMirror.trashedOnSimkl(TraktLibrary(), trashed: [planned]).isEmpty, "not on Simkl: nothing to send")
    }
}
