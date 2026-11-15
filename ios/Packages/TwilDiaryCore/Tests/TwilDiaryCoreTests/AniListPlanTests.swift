import Foundation
import Testing
@testable import TwilDiaryCore

/// Re:Zero as AniList keeps it: season 1 (25), season 2 part 1 (13) and part 2 (12); TMDB numbers
/// season 2 straight through (1-25).
private let reZero = [AniListPlan.Media(id: 21355, format: "TV", episodes: 25, start: "2016-04-04", end: "2016-09-19"),
                      AniListPlan.Media(id: 108632, format: "TV", episodes: 13, start: "2020-07-08", end: "2020-09-30"),
                      AniListPlan.Media(id: 119661, format: "TV", episodes: 12, start: "2021-01-06", end: "2021-03-24")]
private func weekly(_ season: Int, _ range: ClosedRange<Int>, from first: String, startingAt offset: Int = 0, watched: String = "2021-04-07T12:04:00Z") -> [AniListPlan.Watch] {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
    let parts = first.split(separator: "-").compactMap { Int($0) }
    let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    return range.map { number in
        let day = calendar.date(byAdding: .day, value: 7 * (number - range.lowerBound + offset), to: start)!
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return AniListPlan.Watch(season: season, number: number, aired: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), watchedAt: watched)
    }
}

@Test func eachSeasonOrCourGetsTheEpisodesThatAiredInItsRun() {
    let watches = weekly(1, 1...25, from: "2016-04-04") + weekly(2, 1...13, from: "2020-07-08") + weekly(2, 14...16, from: "2021-01-06")
    let plan = AniListPlan.entries(status: "watching", score: 9, film: false, watches: watches, chain: reZero)
    #expect(plan.unplaced == 0)
    #expect(plan.entries.map(\.mediaId) == [21355, 108632, 119661])
    #expect(plan.entries.map(\.status) == ["COMPLETED", "COMPLETED", "CURRENT"])
    #expect(plan.entries.map(\.progress) == [25, 13, 3], "TMDB's S2E14 is part 2's episode 1")
    #expect(plan.entries.allSatisfy { $0.score == 90 })
    #expect(plan.entries[0].completedAt == "2021-04-07" && plan.entries[2].completedAt == nil)
}

@Test func aPlannedTitleIsPlanningOnItsFirstEntryOnly() {
    let plan = AniListPlan.entries(status: "planned", score: nil, film: false, watches: [], chain: reZero)
    #expect(plan.entries == [AniListPlan.Entry(mediaId: 21355, status: "PLANNING", progress: 0)])
    #expect(AniListPlan.entries(status: "watching", score: nil, film: false, watches: [], chain: reZero).entries.isEmpty, "nothing watched, not planned: nothing to send")
}

@Test func aDroppedShowKeepsItsProgressAndARewatchCounts() {
    let dropped = AniListPlan.entries(status: "dropped", score: 4.5, film: false, watches: weekly(1, 1...3, from: "2016-04-04"), chain: reZero)
    #expect(dropped.entries == [AniListPlan.Entry(mediaId: 21355, status: "DROPPED", progress: 3, score: 45, startedAt: "2021-04-07")])
    let twice = weekly(1, 1...25, from: "2016-04-04") + weekly(1, 1...25, from: "2016-04-04", watched: "2023-01-01T00:00:00Z")
    let rewatched = AniListPlan.entries(status: "completed", score: nil, film: false, watches: twice, chain: [reZero[0]])
    #expect(rewatched.entries.first?.repeatCount == 1)
    #expect(rewatched.entries.first?.completedAt == "2023-01-01")
}

@Test func aFilmIsCompletedOnceWatchedAndPlannedBefore() {
    let film = [AniListPlan.Media(id: 156822, format: "MOVIE", episodes: 1, start: "2022-05-13", end: "2022-05-13")]
    let watched = AniListPlan.entries(status: "completed", score: 7, film: true, watches: [
        AniListPlan.Watch(season: nil, number: nil, aired: nil, watchedAt: "2022-06-01T10:00:00Z"),
        AniListPlan.Watch(season: nil, number: nil, aired: nil, watchedAt: "2023-06-01T10:00:00Z")], chain: film)
    #expect(watched.entries == [AniListPlan.Entry(mediaId: 156822, status: "COMPLETED", progress: 1, score: 70, startedAt: "2022-06-01", completedAt: "2023-06-01", repeatCount: 1)])
    #expect(AniListPlan.entries(status: "planned", score: nil, film: true, watches: [], chain: film).entries.map(\.status) == ["PLANNING"])
}

@Test func aWatchWithNoAirDayIsUnplacedWhenTheTitleHasSeveralEntries() {
    let blind = [AniListPlan.Watch(season: 1, number: 1, aired: nil, watchedAt: "2021-04-07T12:04:00Z")]
    #expect(AniListPlan.entries(status: "watching", score: nil, film: false, watches: blind, chain: reZero).unplaced == 1)
    #expect(AniListPlan.entries(status: "watching", score: nil, film: false, watches: blind, chain: [reZero[0]]).entries.first?.progress == 1, "one entry: it's that one")
}

@Test func anAirDayFindsItsEntryWithTwoDaysEitherSide() {
    #expect(AniListPlan.media(for: "2016-04-03", in: reZero)?.id == 21355, "a day early: time zones")
    #expect(AniListPlan.media(for: "2020-10-01", in: reZero)?.id == 108632)
    #expect(AniListPlan.media(for: "2020-12-01", in: reZero)?.id == 108632, "between parts: the one begun latest")
    #expect(AniListPlan.media(for: "2015-01-01", in: reZero) == nil)
}

@Test func theSearchResultNamedTheSameWithinAYearIsTheTitle() {
    let candidates = [
        AniListPlan.Candidate(media: AniListPlan.Media(id: 1, format: "TV", episodes: 12, start: "2008-01-01", end: nil), names: ["Bubble Gum"]),
        AniListPlan.Candidate(media: AniListPlan.Media(id: 2, format: "MOVIE", episodes: 1, start: "2022-02-10", end: nil), names: ["Bubble"]),
        AniListPlan.Candidate(media: AniListPlan.Media(id: 3, format: "ONA", episodes: 1, start: "2022-04-28", end: nil), names: ["Bubble", "バブル"])]
    #expect(AniListPlan.pick(candidates, names: ["Bubble"], year: 2022, film: true)?.id == 2)
    #expect(AniListPlan.pick(candidates, names: ["Bubble"], year: 2008, film: false)?.id == 1, "nothing named so: AniList's best match of the right kind within a year")
    #expect(AniListPlan.pick(candidates, names: ["Something Else"], year: 2022, film: true, strict: true) == nil, "strict: only one named the same")
    #expect(AniListPlan.status("paused") == "PAUSED" && AniListPlan.status("planned") == "PLANNING")
}

@Test func theComparisonFindsMissingDifferentAndExtraEntries() {
    let expected = [
        AniListPlan.Expected(key: "tv:65942", label: "Re:ZERO", entry: AniListPlan.Entry(mediaId: 21355, status: "COMPLETED", progress: 25, score: 90)),
        AniListPlan.Expected(key: "tv:65942", label: "Re:ZERO · 2nd Season", entry: AniListPlan.Entry(mediaId: 108632, status: "CURRENT", progress: 5, score: 90)),
        AniListPlan.Expected(key: "tv:46004", label: "Date A Live", entry: AniListPlan.Entry(mediaId: 15583, status: "COMPLETED", progress: 12, score: 80)),
        AniListPlan.Expected(key: "movie:912598", label: "Bubble", entry: AniListPlan.Entry(mediaId: 142455, status: "PLANNING", progress: 0))]
    let listed = [
        AniListPlan.Listed(mediaId: 21355, listId: 1, status: "REPEATING", progress: 25, score: 90, title: "Re:Zero"),
        AniListPlan.Listed(mediaId: 108632, listId: 2, status: "CURRENT", progress: 3, score: 85, title: "Re:Zero 2nd Season"),
        AniListPlan.Listed(mediaId: 15583, listId: 3, status: "COMPLETED", progress: 12, score: 80, title: "Date A Live"),
        AniListPlan.Listed(mediaId: 1, listId: 4, status: "PLANNING", progress: 0, score: nil, title: "Cowboy Bebop")]
    let result = AniListPlan.compare(expected: expected, listed: listed, notLookedUp: 2)
    #expect(result.matching == 2, "Rewatching counts as Completed")
    #expect(result.different.map(\.detail) == ["5 watched in the diary, 3 on AniList; rated 9 in the diary, 8.5 on AniList"])
    #expect(result.missing.map(\.title) == ["Bubble"])
    #expect(result.onlyOnAniList.map(\.title) == ["Cowboy Bebop"])
    #expect(result.keysToSend == ["movie:912598", "tv:65942"])
    #expect(result.notLookedUp == 2 && !result.matches)
}

@Test func aCompletedSeasonWatchedAgainIsRewatchingWithTheRewatchsProgress() {
    let once = weekly(1, 1...12, from: "2013-04-06", watched: "2021-04-07T12:04:00Z")
    let again = weekly(1, 1...4, from: "2013-04-06", watched: "2024-02-01T20:00:00Z")
    let dateALive = [AniListPlan.Media(id: 15583, format: "TV", episodes: 12, start: "2013-04-06", end: "2013-06-22")]
    let watching = AniListPlan.entries(status: "watching", score: 8, film: false, watches: once + again, chain: dateALive, notes: "  Kurumi!  ")
    #expect(watching.entries == [AniListPlan.Entry(mediaId: 15583, status: "REPEATING", progress: 4, score: 80, startedAt: "2021-04-07", completedAt: "2021-04-07", repeatCount: 0, notes: "Kurumi!")])
    let done = AniListPlan.entries(status: "completed", score: 8, film: false, watches: once + again, chain: dateALive)
    #expect(done.entries.first?.status == "COMPLETED" && done.entries.first?.progress == 12, "finished in the diary: Completed, the rewatch not counted till it's whole")
    #expect(AniListPlan.entries(status: "planned", score: nil, film: true, watches: [], chain: dateALive, notes: "").entries.first?.notes == nil, "an empty note is no note")
}
