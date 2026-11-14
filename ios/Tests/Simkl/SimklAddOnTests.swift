import XCTest
@testable import TwilDiary

/// The Simkl add-on: its copy queue, the bodies it sends, how it reads Simkl's answers, sign-in
/// checks, and that it stays in its folder (so removing it stays one folder and three lines).
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

    func testSignInPageAndReply() throws {
        let attempt = SimklAccount.start { Array(repeating: 7, count: $0) }
        let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(attempt.url.host, "simkl.com")
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "twildiary://auth/simkl")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        let back = try XCTUnwrap(URL(string: "twildiary://auth/simkl?code=abc&state=\(attempt.state)"))
        XCTAssertEqual(try SimklAccount.code(from: back, for: attempt), "abc")
        XCTAssertThrowsError(try SimklAccount.code(from: URL(string: "twildiary://auth/simkl?code=abc&state=other")!, for: attempt))
        XCTAssertThrowsError(try SimklAccount.code(from: URL(string: "twildiary://auth/simkl?error=access_denied&state=\(attempt.state)")!, for: attempt))
    }

    func testTokensNeedWriteAccess() throws {
        let tokens = try SimklAccount.tokens(from: Data(#"{"access_token":"a","refresh_token":"r","expires_in":604800,"scope":"media:read media:write"}"#.utf8), status: 200, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(tokens.expires, Date(timeIntervalSince1970: 604_800))
        XCTAssertThrowsError(try SimklAccount.tokens(from: Data(#"{"access_token":"a","scope":"media:read"}"#.utf8), status: 200), "read-only is refused")
        XCTAssertThrowsError(try SimklAccount.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400))
    }

    // MARK: Contained

    /// Simkl appears only in App/Simkl, its three hook lines, and the few places that named it
    /// before (its logo, the one-time cleanup of the old Simkl support, two comments).
    func testTheAddOnStaysInItsFolder() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("The app's sources aren't on this machine.") }
        // The three hooks, then what named Simkl before the add-on (no more than it did then).
        let allowed = ["TraktDiaryEditing.swift": 1, "ConnectionsView.swift": 1, "TwilDiaryApp.swift": 1,
                       "Components.swift": 3, "DiaryStore.swift": 12, "ServiceIDs.swift": 1, "APIsView.swift": 1]
        var outside: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files where !file.path.contains("/App/Simkl/") {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains("simkl") }
            guard !lines.isEmpty else { continue }
            if let most = allowed[file.lastPathComponent], lines.count <= most { continue }
            outside.append("\(file.lastPathComponent): \(lines.count) line(s)")
        }
        XCTAssertEqual(outside, [], "Simkl code outside App/Simkl: keep the add-on in its folder.")
    }
}
