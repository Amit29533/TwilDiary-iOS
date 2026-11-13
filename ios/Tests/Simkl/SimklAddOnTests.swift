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
        XCTAssertEqual(queue.batch(now: now).map(\.number), [1, 2], "the rating in between keeps episode 3 for later")

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
        XCTAssertEqual(SimklBody.place(day: "2013-04-08", in: list).map { [$0.season, $0.number] }, [1, 1], "TVDB's place, a day off")
        XCTAssertEqual(SimklBody.place(day: "2013-09-28", in: list)?.own, true, "Simkl's own number when TVDB's isn't given")
        XCTAssertEqual(SimklBody.place(day: "2013-12-09", in: list).map { [$0.season, $0.number] }, [0, 1], "a special")
        XCTAssertNil(SimklBody.place(day: "2014-01-01", in: list))
    }

    func testSearchAnswer() {
        XCTAssertEqual(SimklAPI.match(from: Data(#"[{"type":"anime","title":"Attack on Titan","ids":{"simkl":39687,"slug":"attack-on-titan"}}]"#.utf8)),
                       SimklAPI.Match(simkl: 39687, kind: "anime"))
        XCTAssertNil(SimklAPI.match(from: Data("[]".utf8)))
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
